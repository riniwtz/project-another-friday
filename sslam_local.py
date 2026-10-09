"""Local SSLAM inference helpers. Source model: ta012/SSLAM_AS2M_Finetuned.

No cloud APIs are invoked here. Model must be downloaded separately.
"""
from __future__ import annotations

import csv
import math
from pathlib import Path

SAMPLE_RATE = 16_000
TARGET_FRAMES = 1024
MEL_BINS = 128
CHUNK_SAMPLES = 163_840  # 10.24 seconds at 16 kHz
HOP_SAMPLES = 128_000    # 8 seconds, overlapping chunks
NUM_CLASSES = 527
MEAN = -4.268
STD = 4.569


def select_device(requested: str = "auto") -> str:
    import torch

    if requested == "auto":
        return "mps" if torch.backends.mps.is_available() else "cpu"
    if requested == "mps" and not torch.backends.mps.is_available():
        raise RuntimeError("Apple Metal (MPS) is unavailable. Use --device cpu.")
    if requested not in ("mps", "cpu"):
        raise ValueError("device must be auto, mps, or cpu")
    return requested


def load_waveform(path: str | Path):
    """Decode audio, downmix to mono, resample to 16kHz; all on CPU."""
    import soundfile as sf
    import torch
    import torchaudio

    path = Path(path)
    if not path.is_file():
        raise FileNotFoundError(f"Audio not found: {path}")
    audio, sr = sf.read(str(path), always_2d=True, dtype="float32")
    if sr <= 0 or audio.shape[0] == 0:
        raise ValueError("Audio must contain at least one sample")
    if not math.isfinite(float(audio.max())) or not math.isfinite(float(audio.min())):
        raise ValueError("Audio contains non-finite samples")
    # [time, channels] -> [time], preserving a single 16 kHz mono waveform
    mono = torch.from_numpy(audio.mean(axis=1).copy())
    if sr != SAMPLE_RATE:
        mono = torchaudio.functional.resample(mono.unsqueeze(0), sr, SAMPLE_RATE).squeeze(0)
    return mono.contiguous()


def chunk_waveform(waveform, chunk_samples: int = CHUNK_SAMPLES, hop_samples: int = HOP_SAMPLES):
    """Return (start_seconds, waveform) windows. Cover the entire recording."""
    if chunk_samples <= 0 or hop_samples <= 0:
        raise ValueError("chunk_samples and hop_samples must be positive")
    n = int(waveform.numel())
    if n <= 0:
        raise ValueError("Empty waveform")
    if n <= chunk_samples:
        return [(0.0, waveform)]
    starts = list(range(0, n - chunk_samples + 1, hop_samples))
    last_start = n - chunk_samples
    if starts[-1] != last_start:
        starts.append(last_start)
    return [(s / SAMPLE_RATE, waveform[s : s + chunk_samples]) for s in starts]


def waveform_to_fbank(waveform):
    """Match the EAT/SSLAM feature recipe; return [1, 1, 1024, 128]."""
    import torch
    import torch.nn.functional as F
    import torchaudio

    x = waveform.float().cpu()
    if x.ndim != 1 or x.numel() == 0:
        raise ValueError("Expected a nonempty mono waveform of shape [samples]")
    # Avoid Kaldi's short-input edge case
    if x.numel() < 400:
        x = F.pad(x, (0, 400 - x.numel()))
    x = x - x.mean()
    fb = torchaudio.compliance.kaldi.fbank(
        x.unsqueeze(0),
        htk_compat=True,
        sample_frequency=SAMPLE_RATE,
        use_energy=False,
        window_type="hanning",
        num_mel_bins=MEL_BINS,
        dither=0.0,
        frame_shift=10.0,
    )  # [T, F]
    fb = fb[:TARGET_FRAMES]
    if fb.shape[0] < TARGET_FRAMES:
        fb = F.pad(fb, (0, 0, 0, TARGET_FRAMES - fb.shape[0]))
    fb = (fb - MEAN) / (STD * 2.0)
    return fb.unsqueeze(0).unsqueeze(0).contiguous()


def load_labels(csv_path: str | Path) -> list[str]:
    """Read AudioSet's official index -> display_name mapping."""
    path = Path(csv_path)
    if not path.is_file():
        raise FileNotFoundError(
            f"Missing {path}. Run 'python download_model.py' while online "
            "to download AudioSet's labels."
        )
    with path.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        if not {"index", "display_name"}.issubset(reader.fieldnames or []):
            raise ValueError("Label CSV needs index and display_name columns")
        rows = list(reader)
    labels = [None] * NUM_CLASSES
    for row in rows:
        i = int(row["index"])
        if i < 0 or i >= NUM_CLASSES or labels[i] is not None:
            raise ValueError(f"Bad/duplicate AudioSet class index: {i}")
        labels[i] = row["display_name"]
    if len(rows) != NUM_CLASSES or any(not name for name in labels):
        raise ValueError(f"Expected exactly {NUM_CLASSES} indexed class labels; got {len(rows)}")
    return labels


def load_model(model_dir: str | Path, device: str):
    """Load locally downloaded model and execute the author's custom code."""
    import torch
    from transformers import AutoModel

    model_dir = Path(model_dir).resolve()
    required = ["config.json", "model.safetensors", "modeling_eat.py", "eat_model.py", "model_core.py", "configuration_eat.py"]
    missing = [name for name in required if not (model_dir / name).is_file()]
    if missing:
        raise FileNotFoundError(
            f"SSLAM checkpoint incomplete at {model_dir}: missing {', '.join(missing)}. "
            "Run 'python download_model.py' first."
        )
    if (model_dir / "model.safetensors").stat().st_size < 100_000_000:
        raise ValueError("model.safetensors is too small; download was probably incomplete")
    # The model's Hugging Face EAT wrapper uses author-supplied Python code.
    # Only use a model source you have inspected and trust.
    model = AutoModel.from_pretrained(
        str(model_dir),
        trust_remote_code=True,
        local_files_only=True,
        use_safetensors=True,
        torch_dtype=torch.float32,
    )
    return model.eval().to(device)


def predict(model, waveform, device: str, labels: list[str], top_k: int = 10):
    """Multi-label AudioSet predictions; max-pool scores across audio windows."""
    import torch
    if not 1 <= top_k <= NUM_CLASSES:
        raise ValueError(f"top_k must be between 1 and {NUM_CLASSES}")
    if len(labels) != NUM_CLASSES:
        raise ValueError("Expected 527 AudioSet labels")
    chunks = chunk_waveform(waveform)
    probs = []
    with torch.inference_mode():
        for _, chunk in chunks:
            x = waveform_to_fbank(chunk).to(device)
            logits = model(x)
            if logits.shape != (1, NUM_CLASSES):
                raise RuntimeError(f"Expected logits [1,527], got {tuple(logits.shape)}")
            probs.append(torch.sigmoid(logits.detach().float()).cpu().squeeze(0))
    scores = torch.stack(probs).amax(dim=0)
    values, indices = torch.topk(scores, top_k)
    return {
        "duration_seconds": round(waveform.numel() / SAMPLE_RATE, 3),
        "chunks": len(chunks),
        "aggregation": "maximum per-class probability across windows",
        "predictions": [
            {"index": int(i), "label": labels[int(i)], "score": round(float(v), 6)}
            for v, i in zip(values.tolist(), indices.tolist())
        ],
    }


def embed(model, waveform, device: str):
    """CLS-token 768-d representation per window. Returns float32 NumPy [N, D]."""
    import numpy as np
    import torch

    outputs = []
    with torch.inference_mode():
        for _, chunk in chunk_waveform(waveform):
            x = waveform_to_fbank(chunk).to(device)
            features = model.extract_features(x)
            if features.ndim != 3 or features.shape[0] != 1:
                raise RuntimeError(f"Unexpected embeddings shape: {tuple(features.shape)}")
            outputs.append(features[0, 0].detach().cpu().float().numpy())
    return np.stack(outputs, axis=0)
