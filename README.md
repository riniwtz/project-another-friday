# AudioMosaic Live — natural microphone sound classification

A small, **local** Python project using the *actual* Hugging Face checkpoint:
[`hanxunh/AudioMosaic-vit-b16-finetune-as2m`](https://huggingface.co/hanxunh/AudioMosaic-vit-b16-finetune-as2m).

It captures your Mac microphone continuously, takes overlapping windows, applies the
checkpoint's published Kaldi filterbank preprocessing, and reports **real, model-produced
scores** for AudioSet's 527 sound events. It does **not** pretend to hear speech content,
converse with you, transcribe words, or invent environmental descriptions.

## MacBook M2 (8 GB RAM) setup

Requirements: macOS, an available microphone, **Python 3.11**, internet on initial setup,
and enough disk space for about **344 MB** of weights + Python packages.

```bash
cd audiomosaic-live
python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

If `python3.11` is unavailable, install Python 3.11 using your preferred package manager.
A matched PyTorch+torchaudio version pair is required. These packages support native
Apple Silicon Python environments; **do not run under Rosetta** unless necessary.

Check microphones:

```bash
python -m audiomosaic_live --devices
```

Listen continuously, using the default mic and auto-selection of MPS on supported Macs:

```bash
python -m audiomosaic_live --mic
```

If the wrong input device is used, select one from `--devices`:

```bash
python -m audiomosaic_live --mic --input-device 1
```

If MPS is unsupported or fails, try CPU:

```bash
python -m audiomosaic_live --mic --device cpu
```

The first run downloads the fine-tuned weights and the 527-label AudioSet index CSV.
After successful initial downloads, run without network access:

```bash
python -m audiomosaic_live --mic --offline
```

If macOS denies microphone permission, enable it for your terminal app in
**System Settings → Privacy & Security → Microphone**, then reopen the terminal.

## How to test realistically

1. Start in a quiet room (see `Quiet / skipped`).
2. Speak normally (look for `Speech`, `Male speech`, `Female speech`, etc.).
3. Clap, type, play music, rustle paper, or bark a dog sound.
4. Introduce several sounds at once and see whether it returns **multiple labels**.
5. Use a different room/background noise; watch score stability, latency, and false positives.

Example format only (not claimed model output):

```text
[18:20:20 · audio   10.2s · 0.78s inference] Speech: 71% | Inside, small room: 26%
[18:20:22 · audio   12.2s · 0.74s inference] Speech: 76% | Inside, small room: 23%
```

A score such as 71% is the network's **sigmoid output**, **not a calibrated 71% probability**
that the sound is present. AudioSet's validation mAP of 50.19 is not classification
accuracy and does not imply an individual prediction will be correct.

## More responsive live settings (recommended for trying different sounds)

The model's published input is approximately 10.24 seconds. The default window
preserves that context, but frequent updates and faster smoothing can improve
responsiveness without changing the spectrogram duration:

```bash
python -m audiomosaic_live --mic --window 10.24 --hop 0.5 --smooth 0.15 --threshold 0.35 --top 3 --recent-seconds 1
```

For a **faster-changing** prediction when events start and stop, try a shorter
window. Because the released preprocessing pads shorter clips back to the
1024-frame model input, this is a **latency/accuracy trade-off**; evaluate it
against real sounds before assuming it's better:

```bash
python -m audiomosaic_live --mic --window 5.12 --hop 0.5 --smooth 0.15 --threshold 0.35 --top 3 --recent-seconds 1
```

`--recent-seconds 1` checks loudness only in the most recent second. If that
segment falls below `--silence-rms` (default `0.003`), the tool prints
`Quiet / skipped`, clears the smoothed class history, and skips the model for
that update. This helps stop outdated `Speech` detections after talking stops,
but does **not** remove old speech from a window when recent background audio
is loud enough to pass the gate. Test the RMS threshold for your microphone.

**Interpreting your terminal logs:** `audio 100.5s` is total microphone capture
time since startup, not inference latency. The `0.10s inference` number is the
compute time. The hop (`--hop`) controls updates; the audio window (`--window`)
controls how much earlier sound is included. Output percentages are sigmoid
scores, not calibrated probabilities, and AudioSet is multi-label (different
class scores do not sum to 100%).

## Options

```bash
# Classify a local file using the same preprocessing
python -m audiomosaic_live --file examples/dog.wav

# Less frequent prediction updates to reduce CPU/GPU usage
python -m audiomosaic_live --mic --hop 5

# Show fewer lower-scoring labels
python -m audiomosaic_live --mic --threshold 0.35 --top 3

# Disable temporal smoothing for raw per-window predictions
python -m audiomosaic_live --mic --smooth 0

# JSON Lines, useful for integrating with a UI or saving structured test results
python -m audiomosaic_live --mic --json

# Show all options
python -m audiomosaic_live --help
```

`--json` emits classification summaries only, to stdout. Status and downloads go to stderr.
Nothing is sent to a server for inference. Raw microphone recordings are **not saved**.
Downloads from Hugging Face and Google AudioSet happen once when online.

## How listening works

- **Native microphone capture rate:** uses the actual input-device rate (often 44.1/48 kHz).
- **Preprocessing:** the checkpoint's released `modeling.preprocess`, including
  conversion to mono, resampling to **16 kHz**, Kaldi fbank, 128 mel bins,
  pad/truncate to 1024 mel frames, and training-time normalization.
- **Window:** 10.24 seconds by default to roughly match the model's 1024×128 spectrogram.
- **Hop:** 2 seconds by default. Windows overlap, reducing sudden jumps. First prediction
  requires ~10.24s of microphone context. It's near-real-time *tagging*, not instant onset
  detection or frame-accurate sound localization.
- **Processing:** PyTorch eval/inference mode, Apple MPS if available, with automatic
  fallback to CPU for unsupported MPS operations when `--device auto` is used.
- **Silence filter:** an RMS gate skips very quiet windows (the 0.003 cutoff is adjustable).
  Optionally, `--recent-seconds 1` gates on only the newest second, so old speech
  doesn't prevent quiet detection once the microphone becomes quiet.
- **Smoothing:** exponential smoothing (default 0.55) helps keep results readable.
- **Classification:** `sigmoid(logits)` for multi-label sound tagging. Several sounds may
  be detected simultaneously, and the scores need not sum to 1.

If inference takes longer than the hop, updates can arrive late; the tool drops stale
queued microphone packets when its queue fills. For a low-memory M2, start with
`--hop 5 --top 3`, and use `--device cpu` if the MPS backend fails.

## Project layout

```text
audiomosaic-live/
├── audiomosaic_live/
│   ├── __init__.py
│   ├── __main__.py       # CLI: mic, file, devices, JSON output
│   ├── audio.py          # microphone and overlapping windows
│   ├── engine.py         # checkpoint loader + PyTorch inference
│   └── labels.py         # Google AudioSet 527 labels
├── tests/
│   ├── test_audio.py
│   └── test_predictions.py
├── requirements.txt
├── .gitignore
└── README.md
```

### Run unit tests

```bash
python -m pip install pytest
python -m pytest -q
```

Unit tests validate buffering, score filtering and label parsing **without** loading
model weights. For a true inference test, run `--file your.wav` or use your mic on your
actual Mac. This archive does not contain the 344 MB weights or an audio recording.

## Sources and license

- [Model card](https://huggingface.co/hanxunh/AudioMosaic-vit-b16-finetune-as2m) — AudioMosaic weights / architecture, MIT license.
- [Author implementation](https://github.com/HanxunH/AudioMosaic)
- [AudioSet download page](https://research.google.com/audioset/download.html) — Google's 527-event metadata index and dataset licensing.

Use the official model's `modeling.py` downloaded by the Hugging Face snapshot API.
The remote model code is executed locally; review it if your project has stricter
software supply-chain requirements.
