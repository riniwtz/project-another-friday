"""Hugging Face snapshot loader and actual AudioMosaic waveform inference."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import importlib.util
import json
import sys
import time

import numpy as np

REPO_ID = "hanxunh/AudioMosaic-vit-b16-finetune-as2m"


@dataclass(frozen=True)
class Inference:
    scores: np.ndarray  # [527] sigmoid scores for multi-label sound events
    latency_seconds: float


def choose_device(choice: str) -> str:
    import torch

    if choice == "auto":
        if torch.backends.mps.is_available():
            return "mps"
        return "cuda" if torch.cuda.is_available() else "cpu"
    if choice == "mps" and not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is not available. Try --device cpu.")
    if choice == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("CUDA is not available. Try --device cpu.")
    return choice


class AudioMosaic:
    """Actual 527-class checkpoint; no speech simulation or generated text."""

    def __init__(self, device: str = "auto", *, offline: bool = False):
        import torch
        from huggingface_hub import snapshot_download
        from safetensors.torch import load_file

        torch.set_num_threads(min(4, torch.get_num_threads()))
        self.device = choose_device(device)
        self.requested_device = device
        print(f"Loading {REPO_ID} on {self.device}...", file=sys.stderr)
        repo_path = Path(snapshot_download(
            repo_id=REPO_ID,
            allow_patterns=["config.json", "load_model.py", "modeling.py", "model.safetensors"],
            local_files_only=offline,
        ))
        self.repo_path = repo_path
        config = json.loads((repo_path / "config.json").read_text())
        self.preprocessing = config.get("audio_preprocessing", {
            "sample_rate": 16000, "target_length": 1024, "num_mel_bins": 128,
            "norm_mean": -4.2677393, "norm_std": 4.5689974, "frame_shift": 10.0,
        })
        # Model's own vendored architecture & official preprocessing. Avoids
        # silently accepting arbitrary spectrogram shapes or wrong normalization.
        spec = importlib.util.spec_from_file_location("audiomosaic_checkpoint_modeling", repo_path / "modeling.py")
        if spec is None or spec.loader is None:
            raise RuntimeError("Failed to load checkpoint architecture")
        modeling = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = modeling
        spec.loader.exec_module(modeling)
        self.preprocess = modeling.preprocess

        cls_name = config.get("model_class", "AudioMosaicClassifier")
        cls = getattr(modeling, cls_name, None)
        if cls is None:
            raise RuntimeError(f"Checkpoint architecture not found: {cls_name}")
        constructor_args = {k: v for k, v in config.items() if k not in {"model_class", "audio_preprocessing"}}
        self.model = cls(**constructor_args)
        weights = load_file(str(repo_path / "model.safetensors"), device="cpu")
        self.model.load_state_dict(weights, strict=True)
        del weights
        self.model = self.model.eval().to(self.device)
        self.torch = torch
        self.num_classes = int(config.get("num_classes", 527))
        if self.num_classes != 527:
            raise RuntimeError(f"Expected 527 classes, got {self.num_classes}")

    def classify(self, waveform: np.ndarray, sample_rate: int) -> Inference:
        """Use CPU Kaldi feature extraction, then run model on chosen device."""
        torch = self.torch
        wave = np.asarray(waveform, dtype=np.float32).reshape(-1)
        start = time.perf_counter()
        tensor = torch.from_numpy(wave.copy()).unsqueeze(0)
        spectrogram = self.preprocess((tensor, int(sample_rate)), **self.preprocessing)
        if spectrogram.shape != (1, 1, 1024, 128):
            raise RuntimeError(f"Unexpected model input shape: {tuple(spectrogram.shape)}")
        with torch.inference_mode():
            spectrogram = spectrogram.to(self.device)
            try:
                raw = self.model(spectrogram)
            except (RuntimeError, NotImplementedError) as error:
                if self.device != "mps" or self.requested_device != "auto":
                    raise
                print(f"MPS failed ({error}); switching to CPU.", file=sys.stderr)
                self.device = "cpu"
                self.model = self.model.to("cpu")
                raw = self.model(spectrogram.to("cpu"))
            probabilities = raw.sigmoid().float().cpu().reshape(-1).numpy().copy()
        if probabilities.shape != (self.num_classes,):
            raise RuntimeError(f"Unexpected classifier output shape: {probabilities.shape}")
        return Inference(probabilities, time.perf_counter() - start)


class StablePredictions:
    """Temporal smoothing makes overlapping 10s windows less visually jittery."""

    def __init__(self, smoothing: float = 0.55):
        if not 0 <= smoothing < 1:
            raise ValueError("smoothing must be in [0, 1)")
        self.smoothing = smoothing
        self.previous: np.ndarray | None = None

    def update(self, scores: np.ndarray) -> np.ndarray:
        values = np.asarray(scores, dtype=np.float32)
        if self.previous is None:
            smoothed = values.copy()
        else:
            smoothed = self.smoothing * self.previous + (1 - self.smoothing) * values
        self.previous = smoothed
        return smoothed

    def reset(self) -> None:
        self.previous = None


def top_labels(scores: np.ndarray, labels: tuple[str, ...], *, top: int, threshold: float) -> list[tuple[str, float]]:
    if len(scores) != len(labels):
        raise ValueError("Model output and labels are not aligned")
    indexes = np.argsort(scores)[::-1][:top]
    return [(labels[int(i)], float(scores[i])) for i in indexes if float(scores[i]) >= threshold]
