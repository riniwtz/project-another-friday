#!/usr/bin/env python3
"""SSLAM command line: diagnosis, offline inference, embeddings, synthetic test."""
from __future__ import annotations

import argparse
import json
import os
import platform
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DEFAULT_MODEL = ROOT / "models" / "SSLAM_AS2M_Finetuned"
DEFAULT_LABELS = ROOT / "assets" / "class_labels_indices.csv"


def doctor():
    print(f"Python:      {sys.version.split()[0]} ({sys.executable})")
    print(f"System:      {platform.platform()} / {platform.machine()}")
    for name in ("torch", "torchaudio", "numpy", "soundfile", "sounddevice", "transformers", "timm", "huggingface_hub"):
        try:
            mod = __import__(name)
            print(f"{name:14} {getattr(mod, '__version__', 'installed')}")
        except Exception as e:
            print(f"{name:14} MISSING ({e})")
    try:
        import torch
        print(f"MPS available: {torch.backends.mps.is_available()}")
        print(f"MPS built:     {torch.backends.mps.is_built()}")
    except ImportError:
        pass
    print(f"Model:       {DEFAULT_MODEL} (exists: {DEFAULT_MODEL.is_dir()})")
    print(f"Labels:      {DEFAULT_LABELS} (exists: {DEFAULT_LABELS.is_file()})")
    if platform.system() == "Darwin" and platform.machine() != "arm64":
        print("Warning: This Python 3.14/PyTorch configuration targets Apple Silicon (arm64), not Intel.")
    return 0


def generate_sample(out: Path):
    import numpy as np
    import soundfile as sf
    fs = 16_000
    t = np.arange(fs * 4, dtype=np.float32) / fs
    audio = (0.19 * np.sin(2 * np.pi * 440 * t) + 0.08 * np.sin(2 * np.pi * 880 * t)).astype("float32")
    audio[int(2.2*fs):int(2.3*fs)] += 0.25 * np.sin(2 * np.pi * 1250 * t[:int(.1*fs)])
    out.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(out), audio, fs, subtype="PCM_16")
    print(f"Wrote sample {out} ({len(audio)/fs:.1f}s, 16kHz mono). Synthetic tones only; not an accuracy benchmark.")
    return 0


def run(args):
    if args.offline:
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
    from sslam_local import load_model, load_waveform, select_device, predict, embed, load_labels

    device = select_device(args.device)
    print(f"Loading audio {args.audio} ...", file=sys.stderr)
    waveform = load_waveform(args.audio)
    print(f"Loading model from {args.model_dir} on {device} ...", file=sys.stderr)
    model = load_model(args.model_dir, device)
    if args.command == "predict":
        labels = load_labels(args.labels)
        result = predict(model, waveform, device, labels, top_k=args.top_k)
        result.update({"model": "ta012/SSLAM_AS2M_Finetuned", "device": device, "audio": str(args.audio)})
        print(json.dumps(result, indent=2, ensure_ascii=False))
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
            print(f"JSON written: {args.json}", file=sys.stderr)
    else:
        import numpy as np
        features = embed(model, waveform, device)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        np.save(args.output, features)
        print(f"Saved {features.shape} float32 embeddings to {args.output}")
    return 0


def main():
    parser = argparse.ArgumentParser(description="SSLAM local audio event detector for macOS")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("doctor", help="show versions, MPS support, model presence")
    sample = sub.add_parser("sample", help="create a short WAV file for smoke testing")
    sample.add_argument("--output", type=Path, default=ROOT / "demo.wav")
    sub.add_parser("devices", help="list microphone devices and their input indices")
    mic = sub.add_parser("mic-test", help="check macOS mic permission, recording levels, and input device")
    mic.add_argument("--input-device", help="input index or device name substring")
    mic.add_argument("--sample-rate", type=int, help="override input hardware sample rate")
    mic.add_argument("--seconds", type=float, default=3.0)
    mic.add_argument("--output", type=Path, help="optionally save microphone recording locally")

    for command in ("live", "replay"):
        p = sub.add_parser(command, help=("stream sound labels from microphone" if command == "live" else "stream labels from a WAV/FLAC file (no mic)"))
        if command == "replay":
            p.add_argument("audio", type=Path)
        else:
            p.add_argument("--input-device", help="input device index or name substring; default system mic")
            p.add_argument("--sample-rate", type=int, help="force hardware capture sample rate; default device native rate")
        p.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL)
        p.add_argument("--labels", type=Path, default=DEFAULT_LABELS)
        p.add_argument("--device", choices=("auto", "mps", "cpu"), default="auto", help="inference accelerator, not audio input")
        p.add_argument("--offline", action="store_true", help="force offline model loading")
        p.add_argument("--window", type=float, default=10.24, help="rolling seconds of audio analyzed (default 10.24)")
        p.add_argument("--hop", type=float, default=2.0, help="prediction refresh spacing in seconds (default 2)")
        p.add_argument("--warmup", type=float, default=3.0, help="initial (short, padded) prediction after N seconds")
        p.add_argument("--silence-rms", type=float, default=0.003, help="skip nearly silent segments; set 0 to disable")
        p.add_argument("--top-k", type=int, default=5, help="number of model labels per prediction")
        p.add_argument("--min-score", type=float, default=0.1, help="minimum sigmoid score displayed; not confidence")
        p.add_argument("--max-seconds", type=float, help="stop after N seconds of captured/replayed audio")
        p.add_argument("--jsonl", type=Path, help="append label predictions (not raw audio) as local JSON lines")

    for command in ("predict", "embed"):
        p = sub.add_parser(command)
        p.add_argument("audio", type=Path)
        p.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL)
        p.add_argument("--device", choices=("auto", "mps", "cpu"), default="auto")
        p.add_argument("--offline", action="store_true", help="set Hugging Face offline flags")
        if command == "predict":
            p.add_argument("--labels", type=Path, default=DEFAULT_LABELS)
            p.add_argument("--top-k", type=int, default=10)
            p.add_argument("--json", type=Path, help="also save JSON report to this path")
        else:
            p.add_argument("--output", type=Path, default=ROOT / "embedding.npy")
    args = parser.parse_args()
    try:
        if args.command == "doctor":
            return doctor()
        if args.command == "sample":
            return generate_sample(args.output)
        if args.command in ("devices", "mic-test", "live", "replay"):
            from live_audio import list_devices, run_mic_test, run_live, run_replay
            if args.command == "devices":
                return list_devices()
            if args.command == "mic-test":
                return run_mic_test(args)
            if args.max_seconds is not None and args.max_seconds <= 0:
                raise ValueError("--max-seconds must be positive")
            if args.offline:
                os.environ["HF_HUB_OFFLINE"] = "1"
                os.environ["TRANSFORMERS_OFFLINE"] = "1"
            return run_live(args) if args.command == "live" else run_replay(args)
        return run(args)
    except (RuntimeError, ValueError, FileNotFoundError, ImportError, OSError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    except Exception as e:
        # A PortAudioError is not necessarily an OSError, so intercept it
        # separately without masking unexpected application programming bugs.
        if e.__class__.__name__ == "PortAudioError":
            print(f"Microphone/PortAudio error: {e}", file=sys.stderr)
            print("Check macOS Settings > Privacy & Security > Microphone, "
                  "run 'python app.py devices', then 'python app.py mic-test'.", file=sys.stderr)
            return 1
        raise


if __name__ == "__main__":
    sys.exit(main())
