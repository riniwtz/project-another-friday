import numpy as np
import pytest

from audiomosaic_live.audio import RollingAudio, activity_rms, rms


def test_rms_silence_and_signal():
    assert rms(np.zeros(8000, dtype=np.float32)) == 0.0
    assert rms(np.full(100, 0.2, dtype=np.float32)) == pytest.approx(0.2)


def test_rolling_window_warms_up_then_advances():
    buffer = RollingAudio(sample_rate=1000, window_seconds=2, hop_seconds=1)
    assert buffer.push(np.ones(1000)) is None
    first = buffer.push(np.ones(1000) * 2)
    assert first is not None
    assert first.waveform.shape == (2000,)
    assert first.elapsed_seconds == 2.0
    assert first.waveform[0] == 1.0
    assert first.waveform[-1] == 2.0
    second = buffer.push(np.ones(1000) * 3)
    assert second is not None
    assert second.waveform.shape == (2000,)
    assert second.waveform[0] == 2.0
    assert second.waveform[-1] == 3.0


def test_no_update_until_next_hop():
    buffer = RollingAudio(sample_rate=1000, window_seconds=2, hop_seconds=1)
    assert buffer.push(np.zeros(2000)) is not None
    assert buffer.push(np.ones(500)) is None
    assert buffer.push(np.ones(500)) is not None


def test_invalid_hop():
    with pytest.raises(ValueError):
        RollingAudio(sample_rate=1000, window_seconds=2, hop_seconds=3)


def test_recent_activity_gate_ignores_old_audio():
    sample_rate = 1000
    wave = np.concatenate((np.full(9000, 0.3, dtype=np.float32), np.zeros(1000, dtype=np.float32)))
    assert rms(wave) > 0.1
    assert activity_rms(wave, sample_rate, 1.0) == 0.0
    assert activity_rms(wave, sample_rate, 0.0) == pytest.approx(rms(wave))


def test_recent_activity_gate_keeps_new_sound():
    sample_rate = 1000
    wave = np.concatenate((np.zeros(9000, dtype=np.float32), np.full(1000, 0.15, dtype=np.float32)))
    assert activity_rms(wave, sample_rate, 0.5) == pytest.approx(0.15)


def test_activity_gate_validates_arguments():
    with pytest.raises(ValueError):
        activity_rms(np.zeros(1000), 1000, -1)
    with pytest.raises(ValueError):
        activity_rms(np.zeros(1000), 0, 1)
