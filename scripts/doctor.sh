#!/usr/bin/env bash
set -uo pipefail
missing=0
for tool in python3 qs grim slurp wl-copy hyprctl magick tesseract zbarimg fc-match; do
  if command -v "$tool" >/dev/null; then
    printf 'OK       %s\n' "$tool"
  else
    printf 'MISSING  %s\n' "$tool"
    missing=1
  fi
done
if [[ -n ${WAYLAND_DISPLAY:-} ]]; then printf 'OK       Wayland session (%s)\n' "$WAYLAND_DISPLAY"; else echo 'MISSING  WAYLAND_DISPLAY (run graphical actions inside a Wayland session)'; missing=1; fi
if command -v omarchy-shell >/dev/null; then
  if omarchy-shell shell ping >/dev/null 2>&1; then echo 'OK       Omarchy shell IPC'; else echo 'INFO     Omarchy shell unavailable; standalone launcher can be used'; fi
fi
if command -v tesseract >/dev/null; then tesseract --list-langs 2>/dev/null; fi
exit "$missing"
