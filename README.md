# SSLAM local + LIVE MICROPHONE inference — macOS / Python 3.14.8

Tested **code and signal-processing tests on Linux Python 3.13**, but the full 362 MB checkpoint cannot be fetched or executed in the authoring environment. The **macOS 3.14.8 combination must be validated on your device**. This project deliberately avoids old Fairseq/Python 3.9.

Includes **continuous live microphone detection** (using a rolling buffer) and offline file classification. This uses the official **SSLAM_AS2M_Finetuned** checkpoint (527 AudioSet events, ~362 MB) via Hugging Face's author-supplied EAT adapter. The code targets **Apple Silicon, macOS 14 or newer**, Python **3.14.x** (including 3.14.8). Normal CPython is recommended over the free-threaded build. The SSLAM README originally uses Python 3.9.13; this is a newer inference-only setup.

### Menu bar UI (optional)

A local SwiftUI menu bar app lives under [`macos/SSLAMMenuBar/`](macos/SSLAMMenuBar/). Open `SSLAMMenuBar.xcodeproj` in Xcode and run on **My Mac**; v1 uses mock detection events for the menu bar ticker and log. See [`macos/SSLAMMenuBar/README.md`](macos/SSLAMMenuBar/README.md) for menu actions and future Python wiring.

## 1. Installation

```bash
# Verify Apple Silicon and macOS
uname -m                  # arm64
sw_vers -productVersion   # 14.0 or newer
python3.14 --version      # Python 3.14.8

cd sslam_macos_py314
bash setup.sh
source .venv/bin/activate
```

If shell doesn't find Python 3.14, install a regular arm64 CPython 3.14 build and re-run `bash setup.sh`, or point to it with `PYTHON_BIN=/full/path/to/python3.14 bash setup.sh`. Don't install packages into your globally shared Python.

Dependencies are deliberately pinned: `torch==2.14.1`, `torchaudio==2.11.0`, `transformers==4.57.6`, and `sounddevice==0.5.6` (macOS universal2 PortAudio wheel); `timm` for the custom adapter. **Do not install latest Transformers 5.x** without separate testing.

### Updating from the previous SSLAM ZIP

The new ZIP contains **updated `app.py` and `requirements.txt` and a new `live_audio.py` and `tests/test_live_audio.py`**. If you already installed the earlier package, preserve your checkpoint to avoid downloading hundreds of megabytes again:

```bash
# From the directory containing BOTH extracted folders:
cp -R sslam_macos_py314_previous/models sslam_macos_py314/
cp -R sslam_macos_py314_previous/assets sslam_macos_py314/
# Or simply keep your old .venv, models and assets and copy the four changed files.
```

If reusing an existing virtual environment, install the **one new dependency** with `python -m pip install sounddevice==0.5.6` inside your existing venv. If starting fresh, `bash setup.sh` installs everything including microphone support.

## 2. Download checkpoint once (internet required)

```bash
python download_model.py
```

This downloads ~362 MB `model.safetensors` and the adapter's model code to `models/SSLAM_AS2M_Finetuned/`, plus the original 527 AudioSet labels to `assets/`. Ensure you have at least 2 GB of free memory and enough disk for PyTorch + the checkpoint. Model download is once only; inference is offline thereafter.

**Security**: `trust_remote_code=True` runs third-party Python from the checkpoint. Audit it before use in a production/sensitive environment. The adapter code comes from `ta012` on Hugging Face. Consider pinning a fixed Hub commit for reproducibility.

## 3. LIVE microphone: quick start

**You need to download the model once (step 2) before starting.** After download, microphone capture, resampling, and SSLAM inference run **on-device with no cloud service**. The `sounddevice` wheel already bundles PortAudio for macOS; Homebrew/`brew install portaudio` should not be required on a standard arm64 Mac.

```bash
source .venv/bin/activate
python app.py devices                # enumerate microphone input IDs
python app.py mic-test --seconds 3  # verifies macOS mic permission and levels; no model loaded
python app.py live --offline        # start infinite live sound-event recognition
# Press Ctrl+C to stop
```

macOS may ask whether **Terminal**, **iTerm** or your IDE is allowed to access the microphone. Choose Allow. Otherwise open **System Settings → Privacy & Security → Microphone** and enable your terminal/IDE, then restart it if necessary. Check **System Settings → Sound → Input** if no microphone appears.

Example output (illustrative, **not an actual tested prediction**):

```text
Listening: MacBook Pro Microphone (48000 Hz -> SSLAM 16000 Hz; mps)
Window=10.24s, refresh~2s, first estimate after 3s
[    3.0s] Speech 0.72 | Inside, small room 0.34  (650 ms)
[    5.0s] Music 0.51 | Speech 0.42  (610 ms)
```

The first result is available after roughly 3 seconds of collected audio (plus inference time); short initial segments are padded to SSLAM's fixed 1024-frame mel representation and may be less reliable. After 10.24 seconds, the input window is full. A rolling 10.24-second sample window refreshes every 2 seconds, so this is **near-real-time windowed inference, not instant event detection**. Heavier machines can choose a shorter hop, while CPUs may need a longer one. Recorded microphone samples are kept only in a bounded in-memory queue/ring unless you explicitly record them using `mic-test --output`. Predictions printed or logged are 527 AudioSet multi-label model scores, not calibrated probabilities.

### Select microphone / customize speed

```bash
python app.py live --input-device 2 --device cpu --offline
python app.py live --input-device "USB Microphone" --device auto --offline
python app.py live --window 5 --warmup 3 --hop 2 --top-k 5 --min-score 0.15
python app.py live --max-seconds 20 --jsonl events.jsonl --offline
python app.py live --silence-rms 0 --device cpu --offline
```

- `--input-device` selects the **microphone**. `--device auto|mps|cpu` selects the **AI accelerator**; they are intentionally different options.
- Audio uses the hardware's reported **native sample rate** (often 48kHz), captures one mono channel, and resamples in Python to SSLAM's required **16kHz**. Use `--sample-rate` only if the device incorrectly reports its default.
- `--window` supports **1.0–10.24** seconds; 10.24 seconds is preferred for closest alignment with the model's fixed feature size.
- `--warmup` is the first-result audio duration (**1 second to window size**); `--hop` controls prediction refresh spacing. Longer windows can smooth events but add history; shorter windows can have poorer model quality.
- `--silence-rms` skips quiet inputs (default 0.003); set 0 to classify silence anyway. RMS is an amplitude heuristic, not voice activity detection.
- `--min-score` filters which events appear **in Terminal only**; the JSONL always includes the full `--top-k` scores. The model's sigmoid scores are not calibrated confidence.
- `--jsonl events.jsonl` appends timestamped **classification metadata** to local disk (no raw microphone audio).
- `--max-seconds` stops after a fixed amount of recorded audio; press Ctrl+C otherwise.

### Test the live inference pipeline without microphone hardware

```bash
python app.py sample                            # synthetic waveform, not semantic-accuracy test
python app.py replay demo.wav --device cpu --offline --window 4 --warmup 3 --hop 1
python app.py mic-test --seconds 3 --output mic_test.wav
python app.py replay mic_test.wav --offline --window 3 --warmup 3
```

Replay uses the same rolling-window analyzer as live capture but reads a file **as fast as inference permits** rather than at wall-clock speed. With `--max-seconds`, only that much source audio is processed. The optional local mic-test recording remains on disk until you delete it. If `mic-test` returns no input signal, fix microphone permissions first before debugging the model.

## 4. Test all features

```bash
python app.py doctor
python -m unittest discover -s tests -v
python app.py sample                      # creates synthetic demo.wav
python app.py predict demo.wav --top-k 5 --device cpu
python app.py embed demo.wav --device cpu --output embedding.npy
```

Those synthetic test tones validate signal processing and inference plumbing, **not semantic audio-classification accuracy**. For meaningful predictions, feed a real environmental sound file:

```bash
python app.py predict /path/to/real_sound.wav --top-k 10 --json result.json
```

`--device auto` uses **MPS on Apple Silicon** when available, otherwise CPU. In case of MPS runtime errors, rerun with `--device cpu`. Initial model loading may need several GB RAM. Avoid several concurrent model instances.

## 5. Prove offline mode

After successful download, disconnect Wi-Fi and run:

```bash
python app.py predict /path/to/real_sound.wav --offline --device cpu
```

This uses only local model files. No Hugging Face inference endpoint is called. `--offline` also sets `HF_HUB_OFFLINE` and `TRANSFORMERS_OFFLINE`. The only network operation is the one-time `download_model.py` command.

## 6. Technical notes

- Audio: WAV, FLAC, OGG etc. supported by libsndfile / `soundfile`. On some Macs, MP3/M4A require conversion: `ffmpeg -i input.m4a -ar 16000 -ac 1 clean.wav`.
- Stereo is downmixed, resampled to 16 kHz, DC-mean removed, then Kaldi-style 128-bin mel filterbanks are computed (10 ms hop; 1024 frames; mean -4.268, std 4.569*2).
- Input tensor: `[1,1,1024,128]` floating-point.
- Sounds longer than 10.24s are split into overlapping chunks (8s stride); class scores are max-pooled across chunks. Top event scores are **multi-label sigmoid scores**, not calibrated certainty.
- Embeddings: one CLS vector per audio window, shape `[windows,768]`, serialized as `.npy`.
- Label taxonomy comes from Google's 527-class AudioSet index mapping; there are **no hand-authored or guessed labels**.
- SSLAM itself is **not speech-to-text**, and synthetic tones can yield seemingly arbitrary labels. Live microphone and file-replay support do not add transcription.
- **Data flow:** macOS Core Audio/PortAudio → mono float32 capture → bounded queue → rolling NumPy ring → resample to 16kHz CPU tensor → Kaldi mel filterbank → on-device SSLAM (MPS or CPU) → terminal/optional local JSONL. Audio capture callback never executes the neural model.

## Troubleshooting

| Error | Resolution |
|---|---|
| `No matching distribution for torch` | Confirm `uname -m` returns `arm64`, macOS 14+, standard Python 3.14 venv. On Intel, this set of wheels is not supplied; use Apple Silicon or prepare a separately tested legacy CPU configuration. |
| `... model.safetensors missing` | Run `python download_model.py` while online. |
| `No module named 'timm'` | Re-activate venv and re-run `python -m pip install -r requirements.txt`. |
| `Unable to load custom code` | Verify that `models/SSLAM_AS2M_Finetuned/` contains all four `.py` adapter files and that `transformers==4.57.6`. |
| `MPS ... not implemented` | Re-run with `--device cpu`; this indicates a Metal backend incompatibility, not a CPU-mode inference failure. |
| `Error querying device`, `Invalid input device` | Run `python app.py devices`, check **Sound → Input**, and select a correct `--input-device` index. |
| `PortAudioError`, microphone is silent or permission denied | Enable your Terminal/IDE under **Privacy & Security → Microphone**; restart the app and run `python app.py mic-test`. |
| `ModuleNotFoundError: sounddevice` | Run `python -m pip install -r requirements.txt` inside the venv; macOS ARM64 gets the bundled PortAudio wheel. |
| Live output feels delayed | The first inference needs at least `--warmup` seconds; classification covers a rolling window. Try `--window 5 --warmup 3 --hop 2` or `--device cpu` if MPS is incompatible. |
| `class_labels_indices.csv missing` | Re-run the downloader online. The author demo's `vocab` is not bundled in the HF checkpoint; our downloader supplies AudioSet's label CSV. |
| macOS says Python is 3.14 but pip installed elsewhere | Use `python -m pip` *inside* the activated venv (never bare global `pip`). |

## Models & attribution

- Paper + original project: https://github.com/ta012/SSLAM
- Local checkpoint + code: https://huggingface.co/ta012/SSLAM_AS2M_Finetuned
- AudioSet label data: https://github.com/IBM/audioset-classification/blob/master/audioset_classify/metadata/class_labels_indices.csv
- PyTorch/TorchAudio compatibility: https://docs.pytorch.org/audio/main/installation.html

Disclose Hugging Face, PyTorch, SSLAM, and use of AI development tools in hackathon submission. For the hackathon's Local AI requirement, emphasize offline execution rather than the internet being absent in setup.
