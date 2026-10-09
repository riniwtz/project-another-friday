"""Live and replayed sound-event detection with an entirely local SSLAM model.

The PortAudio callback only enqueues copies of microphone samples.  All heavy
resampling, log-mel conversion and inference happens in the main thread.
"""
from __future__ import annotations

import json
import math
import queue
import sys
import time
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np

from sslam_local import CHUNK_SAMPLES, SAMPLE_RATE


def parse_input_device(selection: str | None):
    """Sounddevice accepts int index, substring name, or None for default."""
    if selection is None or not selection.strip():
        return None
    return int(selection) if selection.strip().isdigit() else selection.strip()


def get_input_settings(sd, selection: str | None, sample_rate: int | None = None):
    """Resolve device and its native/default sample rate, and validate audio format."""
    device = parse_input_device(selection)
    info = sd.query_devices(device, kind="input")
    if int(info["max_input_channels"]) < 1:
        raise RuntimeError(f"Audio device {info['name']!r} has no input channels")
    native_sr = int(round(float(info["default_samplerate"])))
    sr = int(sample_rate) if sample_rate is not None else native_sr
    if sr < 8000 or sr > 192000:
        raise ValueError(f"Unsupported capture sample rate: {sr} Hz")
    sd.check_input_settings(device=device, channels=1, dtype="float32", samplerate=sr)
    return device, str(info["name"]), sr


def list_devices():
    import sounddevice as sd

    all_devices = sd.query_devices()
    default_in = sd.default.device[0]
    print("Input devices (use --input-device INDEX or a device-name substring):")
    found = False
    for n, item in enumerate(all_devices):
        if int(item["max_input_channels"]) > 0:
            found = True
            marker = " (default)" if n == default_in else ""
            print(f"  {n:>3}  {item['name']}  | {int(item['default_samplerate'])} Hz{marker}")
    if not found:
        print("No microphone/input device found. Check System Settings > Sound > Input.")
        return 1
    return 0


class AudioRingBuffer:
    """Memory-bounded float32 mono sample ring. No NumPy array growth over time."""

    def __init__(self, capacity_frames: int):
        if capacity_frames < 1:
            raise ValueError("ring capacity must be positive")
        self.data = np.zeros(capacity_frames, dtype=np.float32)
        self.capacity = capacity_frames
        self.filled = 0
        self.next_write = 0
        self.total_received = 0

    def append(self, samples):
        a = np.asarray(samples, dtype=np.float32)
        if a.ndim != 1:
            raise ValueError("Input audio must be one-dimensional mono float32")
        n = int(a.size)
        if n == 0:
            return
        if not np.isfinite(a).all():
            raise ValueError("Microphone provided non-finite samples")
        self.total_received += n
        if n >= self.capacity:
            self.data[:] = a[-self.capacity:]
            self.filled = self.capacity
            self.next_write = 0
            return
        first = min(n, self.capacity - self.next_write)
        self.data[self.next_write:self.next_write + first] = a[:first]
        if n > first:
            self.data[:n - first] = a[first:]
        self.next_write = (self.next_write + n) % self.capacity
        self.filled = min(self.capacity, self.filled + n)

    def snapshot(self):
        """Chronological copy containing up to ``capacity`` newest frames."""
        if self.filled < self.capacity:
            return self.data[:self.filled].copy()
        return np.concatenate((self.data[self.next_write:], self.data[:self.next_write]))


class RollingAudioScheduler:
    """Trigger one prediction per hop, starting once warm-up audio exists."""

    def __init__(self, rate: int, window_seconds: float, hop_seconds: float, warmup_seconds: float):
        if rate < 8000 or rate > 192000:
            raise ValueError("Capture rate must be between 8000 and 192000 Hz")
        if not (1.0 <= window_seconds <= CHUNK_SAMPLES / SAMPLE_RATE):
            raise ValueError("--window must be between 1 and 10.24 seconds (SSLAM's input size)")
        if not (0.25 <= hop_seconds <= window_seconds):
            raise ValueError("--hop must be between 0.25 seconds and --window")
        if not (1.0 <= warmup_seconds <= window_seconds):
            raise ValueError("--warmup must be between 1 second and --window")
        self.rate = rate
        self.window_seconds = window_seconds
        self.hop_seconds = hop_seconds
        self.ring = AudioRingBuffer(max(1, int(math.ceil(rate * window_seconds))))
        self.hop_frames = max(1, int(round(rate * hop_seconds)))
        self.next_prediction_frames = max(1, int(round(rate * warmup_seconds)))

    def push(self, samples):
        self.ring.append(samples)
        total = self.ring.total_received
        if total < self.next_prediction_frames:
            return None
        # On a slow machine skip expired intermediate predictions. Always
        # infer from the latest captured window, never stall the mic callback.
        while self.next_prediction_frames <= total:
            self.next_prediction_frames += self.hop_frames
        captured = self.ring.snapshot()
        return captured, total / self.rate


def to_sslam_waveform(samples: np.ndarray, sample_rate: int):
    """CPU resampling from native mic rate; always feed <=10.24s to SSLAM."""
    import torch
    import torchaudio

    mono = torch.from_numpy(np.ascontiguousarray(samples, dtype=np.float32))
    if sample_rate != SAMPLE_RATE:
        mono = torchaudio.functional.resample(mono.unsqueeze(0), sample_rate, SAMPLE_RATE).squeeze(0)
    return mono[:CHUNK_SAMPLES].contiguous()


class LiveAnalyzer:
    """Pure sample-driven streaming logic, usable for mic and WAV replay."""

    def __init__(self, *, sample_rate: int, window: float, hop: float, warmup: float,
                 silence_rms: float, classify: Callable[[np.ndarray, int], dict[str, Any]]):
        if not (0.0 <= silence_rms <= 1.0):
            raise ValueError("--silence-rms must be between 0 and 1")
        self.scheduler = RollingAudioScheduler(sample_rate, window, hop, warmup)
        self.silence_rms = silence_rms
        self.classify = classify
        self.sample_rate = sample_rate

    def push(self, mono_samples):
        scheduled = self.scheduler.push(mono_samples)
        if scheduled is None:
            return None
        current, end_seconds = scheduled
        rms = float(np.sqrt(np.mean(np.square(current.astype(np.float64)))))
        event: dict[str, Any] = {
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "audio_end_seconds": round(end_seconds, 3),
            "audio_start_seconds": round(max(0., end_seconds - len(current) / self.sample_rate), 3),
            "observed_window_seconds": round(len(current) / self.sample_rate, 3),
            "capture_rate_hz": self.sample_rate,
            "rms": round(rms, 6),
        }
        if rms < self.silence_rms:
            event.update(status="silence", predictions=[], inference_ms=0)
            return event
        start = time.perf_counter()
        result = self.classify(current, self.sample_rate)
        event.update(status="ok", predictions=result["predictions"],
                     inference_ms=round((time.perf_counter() - start) * 1000, 1))
        return event


def _make_classifier(args):
    import torch
    from sslam_local import load_labels, load_model, predict, select_device

    if not 1 <= args.top_k <= 527:
        raise ValueError("--top-k must be between 1 and 527")
    if not (0.0 <= args.min_score <= 1.0):
        raise ValueError("--min-score must be between 0 and 1")
    device = select_device(args.device)
    print(f"Loading SSLAM locally on {device} ...", file=sys.stderr, flush=True)
    labels = load_labels(args.labels)
    model = load_model(args.model_dir, device)

    def classify(samples: np.ndarray, native_rate: int):
        waveform = to_sslam_waveform(samples, native_rate)
        return predict(model, waveform, device, labels, top_k=args.top_k)

    return classify, device


def _print_event(event: dict[str, Any], *, min_score: float):
    end = event["audio_end_seconds"]
    rms = event["rms"]
    if event["status"] == "silence":
        print(f"[{end:7.1f}s] Quiet input (RMS {rms:.4f}); waiting for sound", flush=True)
        return
    top = [p for p in event["predictions"] if p["score"] >= min_score]
    found = " | ".join(f"{p['label']} {p['score']:.2f}" for p in top)
    if not found:
        found = f"No event score >= {min_score:g}"
    print(f"[{end:7.1f}s] {found}  ({event['inference_ms']:.0f} ms)", flush=True)


def _run_analyzer(samples_iter, *, analyzer: LiveAnalyzer, args, source_name: str, max_seconds: float | None):
    """Consume mono blocks; display stdout and optionally append local JSONL."""
    output = None
    if args.jsonl is not None:
        args.jsonl.parent.mkdir(parents=True, exist_ok=True)
        output = args.jsonl.open("a", encoding="utf-8")
    try:
        for block in samples_iter:
            # A mic block may straddle a requested duration; stop at exactly
            # the limit instead of processing unnecessary tail samples.
            if max_seconds is not None:
                limit = int(round(max_seconds * analyzer.sample_rate))
                left = limit - analyzer.scheduler.ring.total_received
                if left <= 0:
                    break
                block = block[:left]
            event = analyzer.push(block)
            if event is not None:
                event["source"] = source_name
                event["model"] = "ta012/SSLAM_AS2M_Finetuned"
                _print_event(event, min_score=args.min_score)
                if output is not None:
                    output.write(json.dumps(event, ensure_ascii=False) + "\n")
                    output.flush()
            if max_seconds is not None and analyzer.scheduler.ring.total_received >= limit:
                break
    finally:
        if output:
            output.close()


def run_live(args):
    """Capture indefinitely until Ctrl+C, optionally ending after N seconds."""
    import sounddevice as sd

    chosen, name, sr = get_input_settings(sd, args.input_device, args.sample_rate)
    # Validate arguments before initializing the expensive neural network.
    RollingAudioScheduler(sr, args.window, args.hop, args.warmup)
    if not 0.0 <= args.silence_rms <= 1.0:
        raise ValueError("--silence-rms must be between 0 and 1")
    classify, device = _make_classifier(args)
    analyzer = LiveAnalyzer(sample_rate=sr, window=args.window, hop=args.hop,
                            warmup=args.warmup, silence_rms=args.silence_rms,
                            classify=classify)
    captured = queue.Queue(maxsize=2048)  # bounded backlog, many seconds of audio
    warnings = queue.Queue(maxsize=100)
    dropped = [0]

    def callback(indata, frames, time_info, status):
        # Important: never call torch or perform blocking inference here.
        if status:
            try:
                warnings.put_nowait(str(status))
            except queue.Full:
                pass
        frame_copy = indata[:, 0].copy()
        try:
            captured.put_nowait(frame_copy)
        except queue.Full:
            # Prefer fresh data over stale predictions on a slow CPU.
            try:
                captured.get_nowait()
            except queue.Empty:
                pass
            try:
                captured.put_nowait(frame_copy)
            except queue.Full:
                pass
            dropped[0] += 1

    def samples():
        while True:
            try:
                batch = captured.get(timeout=1.0)
            except queue.Empty:
                continue
            # Coalesce queued input accumulated during slow inference. That
            # prevents repeated predictions on stale audio while conserving
            # the total captured sample clock and bounded memory.
            pending = [batch]
            while True:
                try:
                    pending.append(captured.get_nowait())
                except queue.Empty:
                    break
            yield pending[0] if len(pending) == 1 else np.concatenate(pending)

    print(f"Listening: {name} ({sr} Hz -> SSLAM 16000 Hz; {device})", flush=True)
    print(f"Window={args.window:g}s, refresh~{args.hop:g}s, first estimate after {args.warmup:g}s", flush=True)
    print("Press Ctrl+C to stop. Microphone audio is not uploaded or saved.", flush=True)
    if args.jsonl:
        print(f"Appending prediction metadata only to {args.jsonl}", flush=True)
    try:
        with sd.InputStream(samplerate=sr, blocksize=0, device=chosen,
                            channels=1, dtype="float32", latency="high", callback=callback):
            _run_analyzer(samples(), analyzer=analyzer, args=args,
                          source_name=f"microphone: {name}", max_seconds=args.max_seconds)
    except KeyboardInterrupt:
        print("\nStopped live microphone inference.")
    finally:
        while not warnings.empty():
            print(f"Audio stream warning: {warnings.get_nowait()}", file=sys.stderr)
        if dropped[0]:
            print(f"Warning: {dropped[0]} audio callbacks dropped (CPU too slow).", file=sys.stderr)
    return 0


def run_replay(args):
    """Exercise exactly the same streaming classification path without a mic."""
    import soundfile as sf
    if not args.audio.is_file():
        raise FileNotFoundError(f"Audio file missing: {args.audio}")
    with sf.SoundFile(str(args.audio)) as f:
        rate = int(f.samplerate)
        RollingAudioScheduler(rate, args.window, args.hop, args.warmup)
        if not 0.0 <= args.silence_rms <= 1.0:
            raise ValueError("--silence-rms must be between 0 and 1")
        classify, device = _make_classifier(args)
        analyzer = LiveAnalyzer(sample_rate=rate, window=args.window, hop=args.hop,
                                warmup=args.warmup, silence_rms=args.silence_rms,
                                classify=classify)
        print(f"Replaying {args.audio} at {rate} Hz on {device} (no microphone needed)")
        def blocks():
            while True:
                chunk = f.read(frames=4096, dtype="float32", always_2d=True)
                if chunk.shape[0] == 0:
                    break
                yield np.ascontiguousarray(chunk.mean(axis=1))
        _run_analyzer(blocks(), analyzer=analyzer, args=args,
                      source_name=f"file: {args.audio}", max_seconds=args.max_seconds)
    return 0


def run_mic_test(args):
    """Test capture + local RMS without downloading/using a model."""
    import sounddevice as sd
    import soundfile as sf

    if not (0.5 <= args.seconds <= 30):
        raise ValueError("--seconds must be between 0.5 and 30")
    chosen, name, sr = get_input_settings(sd, args.input_device, args.sample_rate)
    print(f"Recording {args.seconds:g}s from {name} at {sr} Hz ...", flush=True)
    recorded = sd.rec(int(sr * args.seconds), samplerate=sr, device=chosen,
                      channels=1, dtype="float32", blocking=True)
    mono = recorded[:, 0]
    rms = float(np.sqrt(np.mean(np.square(mono.astype(np.float64)))))
    peak = float(np.max(np.abs(mono)))
    print(f"Microphone OK. RMS={rms:.5f}, peak={peak:.5f}, sample rate={sr} Hz")
    if rms < 0.001:
        print("Very quiet signal: check input selection, microphone mute, and permissions.")
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        sf.write(str(args.output), mono, sr)
        print(f"Saved microphone recording: {args.output}")
    else:
        print("Audio was discarded; supply --output mic_test.wav to save it locally.")
    return 0
