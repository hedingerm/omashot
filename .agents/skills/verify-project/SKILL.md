---
name: verify-project
description: Verify OmaShot changes before claiming them done. Use after any code, QML, test, installer or rendering change, when asked to test/verify/check a change, before committing, and when asked for real-shell or latency evidence. Covers check selection, the scripts/verify.py runner, live Wayland tests, real omarchy-shell verification and known gaps.
---

# Verify OmaShot changes

All paths are relative to the repository root. Run from there.

## Everyday route

```bash
scripts/verify.py --why          # select checks from staged + unstaged + untracked changes vs HEAD, build, run
scripts/verify.py --base main    # also include commits since main (use after committing on a branch)
scripts/verify.py --full         # release route: static, headless, render identity, all live tests (~2.7 min)
scripts/verify.py --list         # check ids and groups; `scripts/verify.py editor-live ui-smoke` runs just those
```

The runner builds `target/debug` and, when a selected test needs it, `target/release` (`capture-*`, `scroll`, `editor-background`, `editor-latency` and `render-identity` use the release binary), so tests never run a stale binary. Checks run in three phases: offscreen checks in parallel (the cargo checks share one lane because of cargo's build lock), alongside a serial lane of live checks (they share focus, pointer and clipboard), then the timing gates `theme-live` and `editor-latency` alone so load can't skew them. `--serial` runs one check at a time, e.g. to rule out load when a check flakes. Each check runs with a timeout in its own process group, output goes to `$TMPDIR/omashot-verify-*/<check>.log` (kept on failure or with `--keep`), and the clipboard is saved and restored around `ui-smoke`/`capture-flow`. The exit status is 0 only if every selected check passed. `BLOCKED` (missing tool/session) and `SKIP` (`--no-live`) are not passes. A changed-scope pass prints "selected subset, not full verification": say exactly that in your report.

Selection rules live in `RULES` in `scripts/verify.py`: unknown paths and the verification tooling itself select the full route; `src/` and `Cargo.*` select everything except the timing gates (~1 min); QML files select their headless and live tests; docs select only the static checks. When you add a test, add it to `CHECKS` (an unregistered `tests/*.py` change selects the full route).

Live checks run in a private, hidden Hyprland nested in the session (window on `special:omashot-verify`, one headless output with the focused monitor's mode and scale, animations off, its own clipboard and pointer), so the user can keep working. If it can't start, live checks report BLOCKED; they never fall back to the desktop. `--desktop` runs them on the visible screen instead (real scanout, e.g. for latency evidence on the display; warn the user first, windows open and `editor-latency` moves the pointer for ~90 s). Shell checks always use the real session. Never pipe the runner or a copying test into `tail`/`grep` (a `wl-copy` daemon inherits the pipe and hangs); redirect to a file.

## What has to be true before "done"

1. The selected checks pass (or the user agreed to a named gap). For a feature, run `--full` once before declaring it finished.
2. **Visible UI or rendering change:** follow the `update-screenshots` skill and look at the images.
3. **User-facing behavior, feel or performance claims:** the user expects evidence from the *installed plugin in the real omarchy-shell* with measured numbers, not only harness runs or screenshots. Ask once, up front, for permission to install, then follow [Real-shell verification](reference.md#real-shell-verification) and run `scripts/verify.py --shell <checks>`. `shell-current` fails if the installed plugin/binary differ from this tree or the shell started before the install.
4. **Render refactors/performance work:** output must stay pixel-identical: `render-golden` (checked-in checksums) and `render-identity` (646 cases vs the `HEAD` binary; `python3 tests/render-identity.py --base <ref>` for another baseline). An intended output change needs a new background/gradient version, never an in-place change (AGENTS.md).
5. **Backend/LiveScene rendering change:** keep `plugin/LiveScene.qml` in step and run `live-scene-fidelity`.
6. Report what ran (the runner's summary), measured numbers, and what stays unproven. Don't round "BLOCKED" or a skipped live tier up to a pass.

## What each check proves

| Check | Oracle |
|---|---|
| `fmt`, `clippy`, `cargo-test`, `py-compile`, `manifest` | CI parity (`.github/workflows/ci.yml`): Rust unit tests incl. stitching/config validation, Cargo/manifest versions match |
| `qmldir` | every plugin QML file except `ShellPalette.qml`, `shell.qml`, `WindowCapture.qml` is listed (otherwise `Theme` breaks inside omarchy-shell) |
| `plugin-validate` | `omarchy plugin validate ./plugin` |
| `install` | isolated HOME: install/update/uninstall, ownership receipts, shell.json merge, launcher routing |
| `render-regression`, `render-golden` | backend render dimensions/hashes; golden decoded-RGBA checksums (ImageMagick-dependent cases skip if the local magick/font key differs; the output says so) |
| `render-identity` | ~650 synthetic render cases pixel-identical to the baseline revision |
| `history-service` | retention, wallpaper library, ownership checks through the CLI |
| `editor-*` (offscreen) | editor event handling, object selection/move, narrow toolbar, background panel, live scene updating synchronously |
| `theme-smoke` | `Theme` follows `OMASHOT_THEME_PATH` changes |
| `ui-smoke` | live capture → quick access → editor → pin, project/export/delete, clipboard pixel equality, OCR, QR |
| `capture-selector`, `capture-flow`, `scroll` | frozen selector geometry and cancel, quick-access stack/actions, frozen OCR, scrolling capture/stitch on real Wayland pixels |
| `isolated-window` | compositor window export: transparent margins, native fractional-scale size, fill color (±3 levels) |
| `theme-live` | omarchy-style Loader hosts, theme fade monotonic at steady frame pacing |
| `live-scene-fidelity` | GPU live preview vs exact backend render for each op/background type |
| `editor-latency` | real virtual-pointer input-to-display latency, fails above 50 ms p90 (typical ≤36 ms) |
| `shell-current`, `shell-latency` | installed plugin equals this tree and is loaded; latency measured in the real shell |

Prerequisites, environment variables and how to read failures: [reference.md](reference.md). Last acceptance run: [acceptance.md](acceptance.md).

## Safety rules (from AGENTS.md, enforced by the tests)

- Tests use temporary `XDG_DATA_HOME`/`XDG_CONFIG_HOME`; never point a test at real user data. New tests must do the same.
- Don't run `scripts/install.sh`/`uninstall.sh`, `omarchy restart shell` or change the theme without the user's approval for that action.
- Other agent sessions may share this worktree: check `git status` before committing and commit only your files. `OMASHOT_TEST_REPORT.md` stays local.

## Keep this skill current

Update this file, `reference.md` and `CHECKS`/`RULES` in `scripts/verify.py` when you add, rename or remove a test, add a QML file, change the installer's file set, change which binary a test uses, or learn a new failure mode. Rerun `scripts/verify.py --full` after changing the runner and record it in `acceptance.md`.
