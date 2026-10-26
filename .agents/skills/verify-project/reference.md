# OmaShot verification reference

Details behind [SKILL.md](SKILL.md). Paths are relative to the repository root.

## Environment

Proven on Omarchy: Hyprland 0.56, Quickshell 0.3.2, ImageMagick 7.1, one 3840×2160 monitor at scale 1.6. Untested: multiple monitors, other scales/transforms, non-English OCR data. CI (`.github/workflows/ci.yml`, Arch container) runs only the static checks plus `install`, `scroll-stitch`, `keybindings` and `verify-runner`; everything else headless/live is local only.

- Static/headless: `cargo`, `jq`, `python3` (stdlib only), `magick`, `qs` (offscreen Qt via `QT_QPA_PLATFORM=offscreen`, set by the tests), `omarchy` for `plugin-validate`.
- Live: a Hyprland session (`WAYLAND_DISPLAY`, `HYPRLAND_INSTANCE_SIGNATURE`) plus `grim`, `wl-paste`, `wl-copy`, `qrencode`, `zbarimg`, `tesseract` (English data), `hyprctl`. `./scripts/doctor.sh` checks runtime dependencies.
- Environment variables the tests set (never real paths): `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `OMASHOT_BACKEND` (binary the QML calls), `OMASHOT_PLUGIN_PATH` (where `WindowCapture.qml` is loaded from), `OMASHOT_THEME_PATH` (fake `~/.local/state/omarchy/current`). The runner writes logs under `TMPDIR` (default `/tmp`).
- Several tests support `--keep DIR` or flags; read the docstring at the top of each `tests/*.py`. `tests/editor-latency-live.py` takes `--plugin DIR`, `--shell` and `--max-ms N`; `tests/render-golden.py --update` rewrites golden checksums (only for an intended, versioned output change); `tests/render-identity.py` takes `--base REF`, `--binary`, `--base-binary`, `-j N`.

## Reading failures

| Signal | Usual cause | What to do |
|---|---|---|
| A live run hangs with no output | output piped and a `wl-copy` daemon inherited the pipe | redirect to a file (the runner does) |
| `JSONDecodeError`, empty output or windows vanish mid-run | omarchy-shell restarted (other sessions reload plugins; check `journalctl --user` for "Exiting due to IPC request"/"reloading") | compare `qs list --all` launch times; rerun |
| Identical `themeStats`/numbers in consecutive real-shell runs | stale singleton or QML in the running shell | `scripts/verify.py shell-current`; `omarchy restart shell` |
| `ReferenceError: Theme is not defined` in a harness | harness copied only some QML files; `Theme` needs `Theme.qml` + `qmldir` | copy the whole `plugin/` dir in harnesses |
| Test exercised old backend behavior | stale `target/release` | use the runner, which rebuilds |
| `render-golden` prints "skipped N ImageMagick renders" | local magick/fonts differ from the golden key | Pure-Rust cases still checked; not a failure |
| Frame-pacing outliers during theme measurements | `omarchy theme set` itself causes 33–93 ms hitches; low battery/power-saving also skews | compare with a control run (same-theme set) and state confounders |
| `theme-live` "starts with the shell palette, lag N" | gate is 25 ms; alone it measures 16–23 ms, 31 ms seen once while other heavy work ran | rerun alone; a repeat failure is a regression |
| `isolated-window` color assert | channels vary by 1–2 levels between runs; the test allows ±3 | larger deviations are real |
| `editor-latency` "interactions not measured" | virtual pointer/keyboard input didn't reach the editor (seen intermittently while the desktop was in use; passed on the next idle run) | rerun with the desktop idle; before 2026-10-25 this case passed vacuously with `{}` results |
| Latency gate failure followed by a parse traceback | the gate failure is real; the traceback is secondary | read the JSON results above it |

## Real-shell verification

Use when the claim is about how the installed app behaves or feels. The real omarchy-shell runs `~/.config/omarchy/plugins/omashot`; only `scripts/install.sh` updates it. **Each step that installs, restarts the shell or switches the theme needs the user's approval.**

1. Note the shell: `qs list --all` (instance id, launch time). Real-shell log: `qs log -i <id>`; IPC: `qs ipc -i <id> call omashot <fn>` (probe functions in `plugin/Main.qml` `IpcHandler`: `themeStats`, `measureFrames`, `editorLatency`, `editorRect`, `editorSetup`). `qs ipc call` splits string arguments, so JSON goes base64-encoded (`editorSetup` decodes it).
2. Before numbers, if the claim is an improvement: `git worktree add --detach <wt> <baseline-ref>`, `cargo build --release` there, `scripts/install.sh --binary <wt>/target/release/omashot` from `<wt>`, `omarchy restart shell`, wait ~5 s, measure. If the baseline lacks the probe IPC functions, patch them into the worktree only.
3. Install this tree: `scripts/install.sh` (rebuilds release, restarts the shell when QML types or singletons changed; otherwise run `omarchy restart shell` yourself, because the shell keeps loaded QML). Then `scripts/verify.py --shell shell-current shell-latency` (or other checks). `shell-current` compares every installed file with the tree and checks the shell started after the install; the runner also fails if the shell instance changes during the run.
4. Restore: reinstall the version the user should end up with, restart the shell, `git worktree remove --force <wt>`. `shell-latency` imports one synthetic capture into the real history and deletes it. Theme experiments: save `readlink ~/.local/state/omarchy/current/background` first and restore it with `omarchy-theme-bg-set <path>`; a same-theme `omarchy theme set` cycles the wallpaper. Palette-only fades without touching terminals/wallpaper: `omarchy-shell shell applyTheme <b64 colors> <b64 shell>`, restore by sending the current theme files.
5. Report before/after numbers with the instance id and anything that disturbed the run.

## Experiments and A/B variants

- Patched plugin copies: `cp -r plugin <scratch>/variant`, patch (e.g. disable a `layer.enabled`, add `console.log("PROF ...")`), run `tests/editor-latency-live.py --plugin <scratch>/variant`. Keep variants in the scratchpad, never in `plugin/`.
- Standalone UI: `OMASHOT_BACKEND="$PWD/target/debug/omashot" qs -p plugin` with temporary XDG dirs, then `qs ipc -p plugin call omashot open`. Stop standalone instances before editing QML (live reload can crash Quickshell); new QML files need a fresh process.
- Offscreen QML harnesses: copy the whole plugin to a temp dir; `PanelWindow` → `FloatingWindow` (strip anchors/margins/WlrLayershell/screen) to click-test layer-shell UI. Call `Qt.quit()` from a Timer. MultiEffect, layer effects and masks render nothing offscreen (software renderer), so check those live. `grabToImage` sizes are multiplied by the device pixel ratio.
- Real input: `tests/vpointer.py` is a stdlib `zwlr_virtual_pointer` client (no ydotool/uinput here).
- Image comparisons: `magick compare -metric AE a.png b.png null:` (count of differing pixels, printed on stderr); compare against `git show HEAD:docs/screenshots/x.png > old.png`. Tiny AE in `launcher.png` is antialiasing noise.

## Known gaps (not covered by any check)

- **Product bug:** `capture repeat` after a frozen area capture (the default) fails with `No such file or directory`, or repeats a stale area, because `capture-frozen` doesn't write `.last-selection`. Reproduced 2026-10-25 at a6d16b6: `omashot snapshot`, `omashot capture-frozen <path> '0,0 100x80'`, `omashot capture repeat`.
- `ScrollCapture.qml` Cancel during an in-flight frame has no dedicated repository check; `capture-flow` checks the final frame on Done, and `scroll-smoke` drives the backend only. Stitching ambiguity that no pixel matcher can resolve (blank stretches, jumps of more than a screenful in blank areas) is listed in README Known limitations.
- Live pixelate/blur previews sample only the base image; a background before a pending transform falls back to the exact render.
- Multi-monitor, other scales, non-English OCR, drag-and-drop into other apps: manual only.
- `editor-latency` thresholds were measured on this machine; another machine may need a different `--max-ms`.
