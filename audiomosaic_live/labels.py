"""Load Google's 527 human-readable AudioSet labels in the model's index order."""
from __future__ import annotations

import csv
import io
from pathlib import Path
from urllib.request import urlopen

# Official AudioSet labels (only downloaded once, alongside the model).
LABEL_URLS = (
    "https://storage.googleapis.com/us_audioset/youtube_corpus/v1/csv/class_labels_indices.csv",
    "https://raw.githubusercontent.com/IBM/audioset-classification/master/audioset_classify/metadata/class_labels_indices.csv",
)


def parse_labels(csv_text: str) -> tuple[str, ...]:
    entries = list(csv.DictReader(io.StringIO(csv_text)))
    if len(entries) != 527:
        raise ValueError(f"Expected 527 AudioSet classes, got {len(entries)}")
    labels = [""] * 527
    for record in entries:
        index = int(record["index"])
        if not 0 <= index < 527 or labels[index]:
            raise ValueError("Duplicate/out-of-range class index")
        labels[index] = record["display_name"].strip()
    if any(not name for name in labels) or labels[0] != "Speech":
        raise ValueError("AudioSet label mapping did not pass validation")
    return tuple(labels)


def load_labels(cache_dir: Path, *, offline: bool = False) -> tuple[str, ...]:
    path = cache_dir / "class_labels_indices.csv"
    if path.exists():
        try:
            return parse_labels(path.read_text(encoding="utf-8"))
        except (ValueError, KeyError):
            if offline:
                raise
    if offline:
        raise FileNotFoundError(f"Missing cached AudioSet labels: {path}")
    failures = []
    for url in LABEL_URLS:
        try:
            with urlopen(url, timeout=30) as response:
                content = response.read().decode("utf-8-sig")
            labels = parse_labels(content)
            cache_dir.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
            return labels
        except Exception as err:
            failures.append(f"{url}: {err}")
    raise RuntimeError("Could not download validated AudioSet labels: " + " | ".join(failures))
