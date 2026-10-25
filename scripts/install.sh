#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
binary=""
reload=1
while (($#)); do
  case $1 in
    --binary) binary=${2:?--binary requires a prebuilt binary}; shift 2 ;;
    --no-reload) reload=0; shift ;;
    -h|--help) echo 'Usage: scripts/install.sh [--binary PATH] [--no-reload]'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ -z $binary ]]; then
  cargo build --release --manifest-path "$repo/Cargo.toml"
  binary="$repo/target/release/omashot"
fi
[[ -x $binary ]] || { echo "Not an executable: $binary" >&2; exit 1; }
python3 "$repo/scripts/install-state.py" install "$repo" "$binary" "$reload"
