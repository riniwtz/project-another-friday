from __future__ import annotations

import csv
import math
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
import soundfile as sf
import torch

from sslam_local import (
    CHUNK_SAMPLES, MEL_BINS, NUM_CLASSES, SAMPLE_RATE, TARGET_FRAMES,
    chunk_waveform, load_labels, load_waveform, predict, embed, waveform_to_fbank,
)


class AudioTests(unittest.TestCase):
    def test_stereo_resample(self):
        fs = 32_000
        t = np.arange(fs, dtype=np.float32) / fs
        samples = np.stack([np.sin(2 * np.pi * 440 * t), np.sin(2 * np.pi * 440 * t)], axis=1)
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "stereo.wav"
            sf.write(path, samples, fs)
            wave = load_waveform(path)
            self.assertEqual(wave.ndim, 1)
            self.assertEqual(wave.numel(), SAMPLE_RATE)
            self.assertLess(float(torch.abs(wave).max()), 1.01)

    def test_fbank_shape_and_finite(self):
        wave = torch.zeros(16_000)
        x = waveform_to_fbank(wave)
        self.assertEqual(tuple(x.shape), (1, 1, TARGET_FRAMES, MEL_BINS))
        self.assertTrue(bool(torch.isfinite(x).all()))

    def test_short_audio(self):
        wave = torch.ones(40)
        self.assertEqual(tuple(waveform_to_fbank(wave).shape), (1, 1, 1024, 128))

    def test_overlapping_chunks_cover_tail(self):
        wave = torch.zeros(CHUNK_SAMPLES * 2 + 10)
        chunks = chunk_waveform(wave)
        self.assertEqual(chunks[0][0], 0)
        self.assertEqual(chunks[-1][1].numel(), CHUNK_SAMPLES)
        self.assertEqual(round(chunks[-1][0] * SAMPLE_RATE), wave.numel() - CHUNK_SAMPLES)

    def test_labels(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "labels.csv"
            with path.open("w", newline="") as f:
                writer = csv.writer(f)
                writer.writerow(["index", "mid", "display_name"])
                for n in range(NUM_CLASSES):
                    writer.writerow([n, f"/m/{n}", f"Event {n}"])
            self.assertEqual(load_labels(path)[526], "Event 526")

    def test_model_prediction_and_embed_with_fake_model(self):
        class FakeModel:
            def __call__(self, x):
                self_input_shape = tuple(x.shape)
                assert self_input_shape == (1, 1, 1024, 128)
                return torch.linspace(-3, 3, NUM_CLASSES).unsqueeze(0)
            def extract_features(self, x):
                return torch.ones(1, 513, 768)

        fake = FakeModel()
        labels = [f"Event {n}" for n in range(NUM_CLASSES)]
        w = torch.zeros(SAMPLE_RATE)
        p = predict(fake, w, "cpu", labels, 3)
        self.assertEqual(p["predictions"][0]["label"], "Event 526")
        self.assertEqual(p["chunks"], 1)
        self.assertEqual(embed(fake, w, "cpu").shape, (1, 768))


if __name__ == "__main__":
    unittest.main()
