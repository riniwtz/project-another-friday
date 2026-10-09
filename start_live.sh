#!/usr/bin/env bash
# Run from Terminal after the one-time model download.
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -x .venv/bin/python ]]; then
  echo 'Missing .venv. Run bash setup.sh first.' >&2
  exit 1
fi
exec .venv/bin/python app.py live --offline "$@"
