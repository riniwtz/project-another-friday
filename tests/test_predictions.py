import numpy as np
import pytest

from audiomosaic_live.engine import StablePredictions, top_labels
from audiomosaic_live.labels import parse_labels


def test_multi_label_threshold_sorting():
    scores = np.array([0.3, 0.8, 0.1], dtype=np.float32)
    assert top_labels(scores, ("speech", "music", "dog"), top=2, threshold=0.2) == [
        ("music", pytest.approx(0.8)), ("speech", pytest.approx(0.3)),
    ]


def test_smoothing_and_reset():
    sm = StablePredictions(0.5)
    np.testing.assert_array_almost_equal(sm.update(np.array([1.0, 0.0])), [1, 0])
    np.testing.assert_array_almost_equal(sm.update(np.array([0.0, 1.0])), [0.5, 0.5])
    sm.reset()
    np.testing.assert_array_almost_equal(sm.update(np.array([0.0, 1.0])), [0, 1])


def test_label_parser_correctly_handles_commas():
    body = ["index,mid,display_name"]
    for i in range(527):
        name = '"Male speech, man speaking"' if i == 1 else ("Speech" if i == 0 else f"Sound {i}")
        body.append(f"{i},/m/id{i},{name}")
    labels = parse_labels("\n".join(body))
    assert len(labels) == 527
    assert labels[1] == "Male speech, man speaking"


def test_label_parser_rejects_misaligned_table():
    with pytest.raises(ValueError):
        parse_labels("index,mid,display_name\n0,/m/09x0r,Speech\n")
