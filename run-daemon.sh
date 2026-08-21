#!/usr/bin/env bash
# Spusti prepisovaci demon v popredi (Ctrl+C ukonci).
# Pro trvaly beh: ./install-daemon.sh
set -euo pipefail
cd "$(dirname "$0")"
exec uv run python dictate/daemon.py
