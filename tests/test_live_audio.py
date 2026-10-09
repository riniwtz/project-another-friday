"""No microphone, model download, or internet required for these tests."""
from __future__ import annotations

import argparse
import json
import math
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
import soundfile as sf

from live_audio import (
    AudioRingBuffer, LiveAnalyzer, RollingAudioScheduler, _run_analyzer,
    get_input_settings, parse_input_device, run_live, run_replay,
    to_sslam_waveform,
)


class RingTests(unittest.TestCase):
    def test_fifo_wrap_and_large_batch(self):
        ring = AudioRingBuffer(5)
        ring.append(np.array([1., 2., 3.]))
        np.testing.assert_array_equal(ring.snapshot(), [1, 2, 3])
        ring.append(np.array([4., 5., 6.]))
        np.testing.assert_array_equal(ring.snapshot(), [2, 3, 4, 5, 6])
        ring.append(np.array([7., 8., 9., 10., 11., 12.]))
        np.testing.assert_array_equal(ring.snapshot(), [8, 9, 10, 11, 12])
        self.assertEqual(ring.total_received, 12)
        self.assertEqual(ring.snapshot().dtype, np.float32)

    def test_reject_invalid_audio(self):
        ring = AudioRingBuffer(8)
        with self.assertRaises(ValueError):
            ring.append(np.zeros((2, 1)))
        with self.assertRaises(ValueError):
            ring.append(np.array([float('nan')]))

    def test_warmup_hop_and_latest_audio(self):
        scheduler = RollingAudioScheduler(8000, window_seconds=2., hop_seconds=1., warmup_seconds=1.)
        self.assertIsNone(scheduler.push(np.ones(6000, np.float32)))
        a, seconds = scheduler.push(np.ones(2000, np.float32))
        self.assertEqual(len(a), 8000)
        self.assertAlmostEqual(seconds, 1.0)
        self.assertIsNone(scheduler.push(np.ones(2000, np.float32)))
        # 2 seconds at once: emits only newest window, skips stale reports
        a, seconds = scheduler.push(np.arange(20000, dtype=np.float32))
        self.assertEqual(len(a), 16000)
        self.assertAlmostEqual(seconds, 3.75)
        self.assertAlmostEqual(a[-1], 19999)

    def test_bad_settings(self):
        with self.assertRaises(ValueError):
            RollingAudioScheduler(48000, 20, 2, 3)
        with self.assertRaises(ValueError):
            RollingAudioScheduler(48000, 2, 2.1, 1)
        with self.assertRaises(ValueError):
            RollingAudioScheduler(48000, 2, 1, 3)


class InferenceTests(unittest.TestCase):
    def test_analyzer_silence_skips_inference(self):
        hits = []
        def fake_clf(s, rate):
            hits.append(len(s))
            return {"predictions": [{"label": "Speech", "score": 0.8, "index": 0}]}
        analyzer = LiveAnalyzer(sample_rate=8000, window=2., hop=1., warmup=1.,
                                silence_rms=.003, classify=fake_clf)
        e = analyzer.push(np.zeros(8000, dtype=np.float32))
        self.assertEqual(e["status"], "silence")
        self.assertEqual(hits, [])
        e = analyzer.push(np.ones(8000, dtype=np.float32) * .03)
        self.assertEqual(e["status"], "ok")
        self.assertEqual(e["predictions"][0]["label"], "Speech")
        self.assertEqual(hits, [16000])
        self.assertEqual(e["audio_end_seconds"], 2.)
        self.assertGreaterEqual(e["inference_ms"], 0)

    def test_resample_mic_native_to_model_rate(self):
        import torch
        x = np.ones(48000, dtype=np.float32) * .1
        tensor = to_sslam_waveform(x, 48000)
        self.assertEqual(tensor.dtype, torch.float32)
        self.assertEqual(tuple(tensor.shape), (16000,))
        tensor = to_sslam_waveform(np.zeros(200000, np.float32), 16000)
        self.assertEqual(tensor.numel(), 163840)

    def test_input_selector(self):
        self.assertEqual(parse_input_device("5"), 5)
        self.assertEqual(parse_input_device(" USB Mic "), "USB Mic")
        self.assertIsNone(parse_input_device(None))
        fake = types.SimpleNamespace(
            query_devices=lambda device, kind: {"name": "Built-in Mic", "max_input_channels": 1, "default_samplerate": 48000.0},
            check_input_settings=lambda **kwargs: None,
        )
        self.assertEqual(get_input_settings(fake, None), (None, "Built-in Mic", 48000))

    @staticmethod
    def make_args(**kwargs):
        defaults = dict(window=2., hop=1., warmup=1., silence_rms=0.,
                        top_k=5, min_score=0., jsonl=None, max_seconds=3.,
                        audio=None, input_device=None, sample_rate=None,
                        model_dir=Path('unused'), labels=Path('unused'), device='cpu')
        defaults.update(kwargs)
        return argparse.Namespace(**defaults)

    @staticmethod
    def dummy_predict(x, rate):
        return {"predictions": [{"index": 0, "label": "Speech", "score": 0.78}]}

    def test_replay_jsonl_end_to_end_without_model_or_microphone(self):
        with tempfile.TemporaryDirectory() as tmp:
            wav = Path(tmp) / 'input.wav'
            output = Path(tmp) / 'events.jsonl'
            sf.write(wav, np.ones(48000 * 4, np.float32) * 0.1, 48000)
            args = self.make_args(audio=wav, jsonl=output, max_seconds=3.)
            with patch('live_audio._make_classifier', return_value=(self.dummy_predict, 'cpu')):
                result = run_replay(args)
            self.assertEqual(result, 0)
            events = [json.loads(line) for line in output.read_text().splitlines()]
            self.assertGreaterEqual(len(events), 2)
            self.assertTrue(all(event['predictions'][0]['label'] == 'Speech' for event in events))
            self.assertLessEqual(events[-1]['audio_end_seconds'], 3.)
            self.assertEqual(events[0]['source'], f'file: {wav}')

    def test_live_callback_with_mock_microphone_stream(self):
        # Exercises callback -> bounded queue -> ring -> predictions -> output
        # without granting a real system microphone permission.
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'live.jsonl'
            args = self.make_args(jsonl=out, max_seconds=2., window=2., hop=1., warmup=1.)
            producers = []
            class FakeInputStream:
                def __init__(self, **kwargs):
                    self.callback = kwargs['callback']
                def __enter__(self):
                    def push_blocks():
                        data = np.ones((4000, 1), dtype=np.float32) * .2
                        for _ in range(30):
                            self.callback(data, 4000, None, None)
                            time.sleep(.0001)
                    self.t = threading.Thread(target=push_blocks, daemon=True)
                    self.t.start()
                    producers.append(self.t)
                    return self
                def __exit__(self, exc_type, exc, tb):
                    self.t.join(timeout=2)
            sd = types.ModuleType('sounddevice')
            sd.InputStream = FakeInputStream
            sd.query_devices = lambda *a, **kw: {'name': 'Mock Mic', 'max_input_channels': 1, 'default_samplerate': 48000.}
            sd.check_input_settings = lambda **kw: None
            with patch.dict(sys.modules, {'sounddevice': sd}):
                with patch('live_audio._make_classifier', return_value=(self.dummy_predict, 'cpu')):
                    self.assertEqual(run_live(args), 0)
            events = [json.loads(line) for line in out.read_text().splitlines()]
            self.assertGreaterEqual(len(events), 1)
            self.assertTrue(all(e['source'] == 'microphone: Mock Mic' for e in events))
            self.assertLessEqual(events[-1]['audio_end_seconds'], 2.)


if __name__ == '__main__':
    unittest.main()
