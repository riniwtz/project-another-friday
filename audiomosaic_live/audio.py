"""Audio buffering, waveform windows, and live microphone capture."""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from queue import Empty, Full, Queue
from typing import Callable, Iterator
import numpy as np


@dataclass(frozen=True)
class AudioWindow:
    waveform: np.ndarray  # mono float32, shape [samples]
    sample_rate: int
    elapsed_seconds: float


def rms(waveform: np.ndarray) -> float:
    """Root mean square loudness, used to avoid hallucinated labels on silence."""
    values = np.asarray(waveform, dtype=np.float32)
    if not values.size:
        return 0.0
    return float(np.sqrt(np.mean(np.square(values, dtype=np.float64))))


def activity_rms(waveform: np.ndarray, sample_rate: int, recent_seconds: float = 0.0) -> float:
    """Return window RMS, or only the most recent audio if recent_seconds > 0.

    Useful in continuous listening: a long context window may contain speech
    from several seconds ago even when the latest mic audio has gone quiet.
    """
    if recent_seconds < 0:
        raise ValueError("recent_seconds must be non-negative")
    if sample_rate <= 0:
        raise ValueError("sample_rate must be positive")
    if recent_seconds == 0:
        return rms(waveform)
    samples = np.asarray(waveform, dtype=np.float32).reshape(-1)
    tail_size = max(1, round(sample_rate * recent_seconds))
    return rms(samples[-tail_size:])


class RollingAudio:
    """Fixed-duration rolling window; emit after initial warmup then every hop.

    Buffer is bounded to window size. Each push may produce zero or one output;
    microphone callback blocks must be shorter than the hop (normal usage).
    """

    def __init__(self, sample_rate: int, window_seconds: float, hop_seconds: float):
        if sample_rate < 1000 or window_seconds <= 0 or hop_seconds <= 0:
            raise ValueError("Invalid audio sample rate, window, or hop")
        if hop_seconds > window_seconds:
            raise ValueError("Hop cannot exceed window length")
        self.sample_rate = int(sample_rate)
        self.window_samples = round(sample_rate * window_seconds)
        self.hop_samples = round(sample_rate * hop_seconds)
        if self.hop_samples < 1 or self.window_samples < 1:
            raise ValueError("Window and hop must each contain at least one sample")
        self._chunks: deque[np.ndarray] = deque()
        self._buffered = 0
        self._total = 0
        self._next_output_at = self.window_samples

    def push(self, samples: np.ndarray) -> AudioWindow | None:
        arr = np.asarray(samples, dtype=np.float32).reshape(-1)
        if arr.size == 0:
            return None
        self._chunks.append(arr)
        self._buffered += arr.size
        self._total += arr.size
        while self._buffered > self.window_samples:
            extra = self._buffered - self.window_samples
            oldest = self._chunks[0]
            if extra >= oldest.size:
                self._chunks.popleft()
                self._buffered -= oldest.size
            else:
                self._chunks[0] = oldest[extra:]
                self._buffered -= extra
        if self._total < self._next_output_at or self._buffered < self.window_samples:
            return None
        self._next_output_at = self._total + self.hop_samples
        wave = np.concatenate(tuple(self._chunks)).copy()
        return AudioWindow(wave, self.sample_rate, self._total / self.sample_rate)


def microphone_windows(
    *, device: int | None, window_seconds: float, hop_seconds: float,
    warning: Callable[[str], None] = print,
) -> Iterator[AudioWindow]:
    """Yield rolling microphone windows. Callback only copies audio into a queue."""
    import sounddevice as sd

    info = sd.query_devices(device, "input")
    sample_rate = round(float(info["default_samplerate"]))
    if sample_rate < 1000:
        raise RuntimeError(f"Invalid microphone sample rate: {sample_rate}")
    buffer = RollingAudio(sample_rate, window_seconds, hop_seconds)
    packets: Queue[np.ndarray] = Queue(maxsize=96)
    dropped = [0]
    warnings: Queue[str] = Queue(maxsize=16)

    def on_audio(indata, frames, time_info, status):  # called by PortAudio
        if status:
            try:
                warnings.put_nowait(str(status))
            except Full:
                pass
        block = indata[:, 0].copy()  # mono; no inference in realtime callback
        try:
            packets.put_nowait(block)
        except Full:
            # Prefer fresh audio over building seconds of stale inference backlog.
            try:
                packets.get_nowait()
            except Empty:
                pass
            try:
                packets.put_nowait(block)
            except Full:
                pass
            dropped[0] += 1

    with sd.InputStream(
        device=device,
        samplerate=sample_rate,
        channels=1,
        dtype="float32",
        blocksize=0,
        callback=on_audio,
    ):
        last_drops = 0
        while True:
            try:
                packet = packets.get(timeout=1.0)
            except Empty:
                continue
            while not warnings.empty():
                warning(f"Microphone warning: {warnings.get_nowait()}")
            if dropped[0] != last_drops:
                warning("Inference slower than the microphone; old audio discarded.")
                last_drops = dropped[0]
            window = buffer.push(packet)
            if window is not None:
                yield window


def file_windows(
    path: str, *, window_seconds: float, hop_seconds: float,
) -> Iterator[AudioWindow]:
    """Read file in its original sample rate and emit overlapping windows.

    A short file is right-padded once to the model's desired window duration.
    """
    import soundfile as sf

    data, sample_rate = sf.read(path, dtype="float32", always_2d=True)
    mono = data.mean(axis=1, dtype=np.float32)
    if mono.size == 0:
        raise ValueError("Audio file is empty")
    samples_per_window = round(sample_rate * window_seconds)
    samples_per_hop = round(sample_rate * hop_seconds)
    if samples_per_window < 1 or samples_per_hop < 1:
        raise ValueError("Window and hop must each contain at least one sample")
    if mono.size <= samples_per_window:
        padded = np.pad(mono, (0, max(0, samples_per_window - mono.size)))
        yield AudioWindow(padded, sample_rate, float(mono.size / sample_rate))
        return
    for start in range(0, mono.size - samples_per_window + 1, samples_per_hop):
        end = start + samples_per_window
        yield AudioWindow(mono[start:end], sample_rate, end / sample_rate)
    # Cover the final part even when the hop doesn't align with the end.
    last_start = mono.size - samples_per_window
    if last_start % samples_per_hop != 0:
        yield AudioWindow(mono[-samples_per_window:], sample_rate, mono.size / sample_rate)
