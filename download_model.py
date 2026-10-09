#!/usr/bin/env python3
"""One-time network download. Runtime inference uses files on disk only."""
from __future__ import annotations

import csv
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MODEL_ID = "ta012/SSLAM_AS2M_Finetuned"
LABELS_URL = (
    "https://raw.githubusercontent.com/IBM/audioset-classification/"
    "master/audioset_classify/metadata/class_labels_indices.csv"
)


def main():
    from huggingface_hub import snapshot_download
    from sslam_local import load_labels

    dest = ROOT / "models" / "SSLAM_AS2M_Finetuned"
    dest.mkdir(parents=True, exist_ok=True)
    print(f"Downloading ~362 MB SSLAM checkpoint and Python model files to {dest}")
    snapshot_download(
        repo_id=MODEL_ID,
        local_dir=str(dest),
        allow_patterns=["*.json", "*.py", "*.safetensors", "README.md"],
    )
    weights = dest / "model.safetensors"
    if not weights.is_file() or weights.stat().st_size < 100_000_000:
        raise RuntimeError("Model weights failed to download correctly")
    label_file = ROOT / "assets" / "class_labels_indices.csv"
    label_file.parent.mkdir(parents=True, exist_ok=True)
    if not label_file.is_file():
        print("Downloading AudioSet class labels...")
        with urllib.request.urlopen(LABELS_URL, timeout=45) as response:
            label_file.write_bytes(response.read())
    try:
        labels = load_labels(label_file)
    except Exception:
        label_file.unlink(missing_ok=True)
        raise
    print(f"Ready! Checkpoint: {weights.stat().st_size:,} bytes; labels: {len(labels)}")
    print("You can now unplug Wi-Fi and run: python app.py predict demo.wav --offline")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Download failed: {exc}", file=sys.stderr)
        sys.exit(1)
