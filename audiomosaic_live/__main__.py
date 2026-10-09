"""Command-line live mic / local audio file tester for AudioMosaic AS2M."""
from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import sys

from .audio import activity_rms, file_windows, microphone_windows, rms
from .engine import AudioMosaic, StablePredictions, top_labels
from .labels import load_labels


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python -m audiomosaic_live",
        description="Classify real ambient microphone audio with AudioMosaic (not speech recognition).",
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--mic", action="store_true", help="Listen continuously to default microphone")
    source.add_argument("--file", metavar="PATH", help="Classify a local WAV/FLAC or soundfile-compatible audio file")
    source.add_argument("--devices", action="store_true", help="List PortAudio input/output devices")
    parser.add_argument("--input-device", type=int, help="Microphone device index from --devices")
    parser.add_argument("--device", choices=("auto", "cpu", "mps", "cuda"), default="auto", help="PyTorch execution device")
    parser.add_argument("--window", type=float, default=10.24, help="Audio context window seconds (default: 10.24)")
    parser.add_argument("--hop", type=float, default=2.0, help="Seconds between live predictions (default: 2.0)")
    parser.add_argument("--threshold", type=float, default=0.20, help="Minimum model score to show (default: 0.20)")
    parser.add_argument("--silence-rms", type=float, default=0.003, help="Skip sound inference below RMS (default: 0.003)")
    parser.add_argument(
        "--recent-seconds", type=float, default=0.0,
        help="Check only the newest N seconds for silence (0: entire window; default: 0)",
    )
    parser.add_argument("--smooth", type=float, default=0.55, help="Temporal smoothing: 0 off, closer to 1 smoother")
    parser.add_argument("--top", type=int, default=5, help="Maximum classes to show (default: 5)")
    parser.add_argument("--json", action="store_true", help="Output JSON Lines instead of terminal text")
    parser.add_argument("--offline", action="store_true", help="Use previously downloaded model and label files only")
    args = parser.parse_args(argv)
    if not 0.0 <= args.threshold <= 1.0:
        parser.error("--threshold must be between 0 and 1")
    if args.top < 1 or args.top > 527:
        parser.error("--top must be between 1 and 527")
    if args.window <= 0 or args.hop <= 0 or args.hop > args.window:
        parser.error("Require 0 < --hop <= --window")
    if args.silence_rms < 0:
        parser.error("--silence-rms must be non-negative")
    if args.recent_seconds < 0 or args.recent_seconds > args.window:
        parser.error("Require 0 <= --recent-seconds <= --window")
    if not 0 <= args.smooth < 1:
        parser.error("--smooth must be in [0, 1)")
    return args


def display(
    *, elapsed: float, loudness: float, events: list[tuple[str, float]],
    latency_seconds: float, status: str, json_mode: bool,
) -> None:
    now = datetime.now().astimezone().isoformat(timespec="seconds")
    if json_mode:
        print(json.dumps({
            "timestamp": now, "elapsed_seconds": round(elapsed, 2),
            "status": status, "rms": round(loudness, 5),
            "inference_seconds": round(latency_seconds, 3),
            "events": [{"label": name, "score": round(score, 4)} for name, score in events],
        }), flush=True)
        return
    time_only = now.split("T", 1)[1][:8]
    label = (
        " | ".join(f"{name}: {score:.0%}" for name, score in events)
        if events else ("Quiet / skipped" if status == "quiet" else "No class above threshold")
    )
    print(f"[{time_only} · audio {elapsed:6.1f}s · {latency_seconds:.2f}s inference] {label}", flush=True)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.devices:
        try:
            import sounddevice as sd
            print(sd.query_devices())
            return 0
        except Exception as exc:
            print(f"Audio device error: {exc}", file=sys.stderr)
            return 1

    try:
        labels = load_labels(Path.home() / ".cache" / "audiomosaic_live", offline=args.offline)
        model = AudioMosaic(args.device, offline=args.offline)
        smoother = StablePredictions(args.smooth)
        if args.mic:
            source = microphone_windows(
                device=args.input_device, window_seconds=args.window, hop_seconds=args.hop,
                warning=lambda msg: print(msg, file=sys.stderr),
            )
            print(f"Microphone running at native input sample rate. Collecting {args.window:g}s initial audio; Ctrl+C stops.", file=sys.stderr)
            print("Not speech-to-text: output is AudioSet sound classes with model scores.", file=sys.stderr)
            if args.recent_seconds:
                print(f"Recent-activity silence gate: last {args.recent_seconds:g}s (threshold {args.silence_rms:g}).", file=sys.stderr)
        else:
            if not Path(args.file).is_file():
                raise FileNotFoundError(f"Audio file does not exist: {args.file}")
            source = file_windows(args.file, window_seconds=args.window, hop_seconds=args.hop)
            print(f"Classifying {args.file}", file=sys.stderr)

        for window in source:
            volume = rms(window.waveform)
            activity = activity_rms(window.waveform, window.sample_rate, args.recent_seconds)
            if activity < args.silence_rms:
                smoother.reset()
                events: list[tuple[str, float]] = []
                status = "quiet"
                latency = 0.0
            else:
                result = model.classify(window.waveform, window.sample_rate)
                smoothed = smoother.update(result.scores)
                events = top_labels(smoothed, labels, top=args.top, threshold=args.threshold)
                status = "detected" if events else "uncertain"
                latency = result.latency_seconds
            display(
                elapsed=window.elapsed_seconds, loudness=volume,
                events=events, status=status, latency_seconds=latency,
                json_mode=args.json,
            )
        return 0
    except KeyboardInterrupt:
        print("\nMicrophone stopped. No raw audio was saved.", file=sys.stderr)
        return 0
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        print("Tip: Check README.md, --devices, macOS microphone access, or try --device cpu.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
