# OmaShot identity

An original open **O** with a detached viewfinder corner: a capture frame that also works as a monogram. Coral `#ff645e` and amber `#ffbe63` sit on ink `#171b29`. The product name is always **OmaShot**; commands and filenames use `omashot`.

- `omashot-app.svg`: application badge, with transparent space around the rounded tile.
- `omashot-mark.svg`: transparent standalone mark; monochrome and white variants are included.
- `omashot-logo-dark.svg` / `omashot-logo-light.svg`: outlined wordmarks for light and dark surfaces. No font is needed to display them.
- `omashot-{16…1024}.png`: app icons rendered from the same vector geometry.
- `brand-preview.png`: light/dark identity and small-size review.

Keep the proportions and colors intact. Allow clear space around the mark of at least one stroke width. Use the app badge for launchers and the transparent mark inside the app.

Rebuild from the repository root with `uv run --with fonttools python scripts/brand-assets.py` (requires `rsvg-convert` and Noto Sans Bold). Noto Sans is licensed under the SIL Open Font License; the included wordmarks contain vector outlines, not font software. The mark and brand assets share the project's MIT license.
