#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
PYTHON_BIN="${PYTHON_BIN:-python3.14}"
"$PYTHON_BIN" - <<'PY'
import platform, sys
assert sys.version_info[:2] == (3, 14), f"Expected Python 3.14.x, got {sys.version}"
if platform.system() != "Darwin" or platform.machine() != "arm64":
    raise SystemExit("This installer targets macOS Apple Silicon (arm64). See README for limitations.")
print("Python:", sys.version.split()[0], "System:", platform.platform())
PY
"$PYTHON_BIN" -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip setuptools wheel
python -m pip install --only-binary=:all: -r requirements.txt
python app.py doctor
printf '\nInstallation finished. Download model: .venv/bin/python download_model.py\n'
