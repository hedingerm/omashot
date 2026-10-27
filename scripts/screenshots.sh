#!/usr/bin/env bash
# Regenerate the README images in docs/screenshots/ from synthetic sources.
# Uses isolated data/config directories and grabs only app content: never touches real captures or
# includes the desktop. The launcher needs layer-shell, so it briefly opens a window on Wayland.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$repo/docs/screenshots"
src="$out/source"
for tool in cargo chromium magick qs python3; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

cargo build --quiet --manifest-path "$repo/Cargo.toml"
backend="${CARGO_TARGET_DIR:-$repo/target}/debug/omashot"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export XDG_DATA_HOME="$work/data" XDG_CONFIG_HOME="$work/config"
# The UI follows the active Omarchy theme; pin a stock one so the images don't depend on this machine.
theme=${OMASHOT_SCREENSHOT_THEME:-tokyo-night}
theme_colors="${OMARCHY_PATH:-/usr/share/omarchy}/themes/$theme/colors.toml"
[[ -f $theme_colors ]] || { echo "Missing Omarchy theme: $theme_colors" >&2; exit 1; }
mkdir -p "$work/theme-state/theme"
cp "$theme_colors" "$work/theme-state/theme/"
echo "$theme" >"$work/theme-state/theme.name"
export OMASHOT_THEME_PATH="$work/theme-state"

shot() { # harness output qt-platform
  local log="$work/$(basename "$1" .qml).log"
  cp -r "$repo/plugin" "$work/plugin-$1"
  cp "$src/$1" "$work/plugin-$1/"
  QT_QPA_PLATFORM=$3 OMASHOT_BACKEND="$backend" OMASHOT_SCREENSHOT="$2" \
    timeout 60 qs -p "$work/plugin-$1/$1" >"$log" 2>&1 || true
  grep -q SHOT_SAVED "$log" || { echo "Failed to render $(basename "$2"):" >&2; cat "$log" >&2; exit 1; }
}

echo 'Rendering demo dashboard'
chromium --headless=new --disable-gpu --hide-scrollbars --window-size=1200,760 \
  --force-device-scale-factor=1 --user-data-dir="$work/chromium" \
  --screenshot="$work/before.png" "file://$src/dashboard.html" >/dev/null 2>&1
[[ -s $work/before.png ]] || { echo 'Chromium did not produce a screenshot' >&2; exit 1; }

echo 'Rendering annotated hero'
"$backend" render "$work/before.png" "$src/annotations.json" "$work/hero.png" >/dev/null

echo 'Rendering background gallery'
"$backend" backgrounds >/dev/null
mkdir "$work/tiles"
for f in "$XDG_DATA_HOME"/omashot/backgrounds-v2/mesh-*.png; do
  magick "$f" -resize 160x110^ -gravity center -extent 160x110 \
    \( -size 160x110 xc:none -fill white -draw 'roundrectangle 0,0 159,109 14,14' \) \
    -compose DstIn -composite "$work/tiles/$(basename "$f")"
done
magick montage "$work"/tiles/*.png -tile 10x2 -geometry +8+8 -background none -depth 8 "$work/backgrounds.png"

echo 'Rendering editor'
# Edits autosave over history captures only, so the editor opens an imported copy.
editor_source=$("$backend" import "$work/before.png" | python3 -c 'import json, sys; print(json.load(sys.stdin)["path"])')
OMASHOT_SOURCE="$editor_source" OMASHOT_OPS=$(cat "$src/annotations.json") shot EditorShot.qml "$work/editor.png" offscreen

echo 'Rendering launcher'
[[ -n ${WAYLAND_DISPLAY:-} ]] || { echo 'The launcher screenshot needs a Wayland session' >&2; exit 1; }
shot LauncherShot.qml "$work/launcher.png" wayland

for name in before hero backgrounds editor launcher; do
  # Strip timestamps and other metadata so unchanged images produce no git diff.
  magick "$work/$name.png" -strip "$out/$name.png"
done
echo "Updated $out:"
ls -1 "$out"/*.png
