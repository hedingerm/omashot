#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
reload=1
case ${1:-} in
  --no-reload) reload=0 ;;
  '') ;;
  *) echo 'Usage: scripts/uninstall.sh [--no-reload]' >&2; exit 2 ;;
esac
python3 "$repo/scripts/install-state.py" uninstall "$reload"
