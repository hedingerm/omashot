# Contributing to OmaShot

Thanks for helping out. OmaShot is a small project, so keep changes focused and easy to review.

## Before you start

- For anything bigger than a bug fix, open an issue first so we can agree on the approach.
- Screen recording and cloud upload are out of scope.
- Use original code and artwork only. Don't copy assets, icons or screenshots from other screenshot products.

## Setup

You need an Omarchy (Hyprland) session for anything that touches the UI. Install the runtime dependencies listed in the [README](README.md#install) and Rust (stable), then:

```bash
./scripts/doctor.sh
cargo build
OMASHOT_BACKEND="$PWD/target/debug/omashot" qs -p plugin
qs ipc -p plugin call omashot open   # from another terminal
```

Stop standalone `qs` instances before editing QML and start a fresh one afterwards; live reload can crash Quickshell. New QML files also need a fresh process (or `omarchy restart shell` for the installed plugin).

## Project layout

- `src/` — Rust backend (`omashot` CLI). Every command prints a single JSON value; errors print `{"error": ...}` and exit 1.
- `plugin/` — Quickshell/QML Omarchy plugin that calls the backend.
- `scripts/` — installer, uninstaller, launcher and brand asset generator.
- `tests/` — integration and smoke tests.

[AGENTS.md](AGENTS.md) has a detailed map and the project's invariants; it is useful for humans too.

## Checks

`scripts/verify.py` picks the checks below that match your changes, builds the binaries they use and runs them (`--full` runs everything, `--list` shows the checks). The details:

Run these before opening a pull request (CI runs the first four):

```bash
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test --locked
bash tests/install.sh
omarchy plugin validate ./plugin
```

Then run the tests relevant to your change (after `cargo build`):

- Headless: `tests/render-regression.py`, `tests/history-service.py`, `tests/editor-*-smoke.py`, `tests/theme-smoke.py` (offscreen Qt, needs Quickshell).
- Live Wayland session: `tests/ui-smoke.py`, `tests/capture-*-smoke.py`, `tests/isolated-window-smoke.py`, `tests/scroll-smoke.py`, `tests/theme-live-smoke.py` (loads the plugin the way omarchy-shell does and checks the theme fade holds frame pacing), `tests/live-scene-fidelity.py` (the editor's live GPU preview matches the exact backend render) and `tests/editor-latency-live.py` (input-to-display latency of drawing, moving, resizing, undo/redo and sliders, driven by a real virtual pointer; `--shell` measures the installed plugin, `--max-ms N` fails above N ms at p90). These open real windows, `editor-latency-live.py` moves your pointer, and `ui-smoke.py` overwrites your clipboard.

## Theme colors

All UI colors come from `plugin/Theme.qml`, which follows the active Omarchy theme live. Don't hardcode chrome colors: use its roles (`window`, `panel`, `surface`, `raised`, `border`, `text`, `textMuted`, `accent`, `accentText`, …). Give each new window root and every `Popup`/`Menu`/`Dialog` `palette: Theme.controls.palette`, because popups don't inherit palettes. List new QML files in `plugin/qmldir`, or the `Theme` singleton won't resolve inside omarchy-shell. Inside the shell, `Theme` takes its base colors from the shell palette through `ShellPalette.qml`. `omarchy-shell omashot themeStats` reports frame pacing of the last fade.

## Screenshots

The README images are generated, not hand-made. After a visible UI or rendering change, run:

```bash
./scripts/screenshots.sh
```

It renders a synthetic demo dashboard (`docs/screenshots/source/dashboard.html`), applies `annotations.json` with the real backend, grabs the editor offscreen and briefly opens the launcher on Wayland, then rewrites `docs/screenshots/*.png`. It uses temporary data directories and only captures OmaShot's own windows, never your desktop. The UI is rendered in Omarchy's default Tokyo Night theme, whatever theme you use; set `OMASHOT_SCREENSHOT_THEME=<stock theme>` to try another one. Check the result and commit the changed images with your pull request.

Tests use temporary `XDG_DATA_HOME`/`XDG_CONFIG_HOME` directories. Keep it that way for new tests; never touch real user data.

## Pull requests

- One topic per pull request, with a short description of what changed and how you tested it.
- Include a screenshot or short clip for visible UI changes.
- Add or update tests for behavior changes, and update the README when user-facing behavior changes.
- Keep `Cargo.toml` and `plugin/manifest.json` versions in sync (maintainers bump them at release time).
- Match the existing code style; prefer system tools (grim, slurp, ImageMagick, Tesseract, zbar) over new dependencies.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
