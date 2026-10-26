# Verification system acceptance

## 2026-10-25: initial setup

- **Source:** a6d16b6 plus the uncommitted verification files (runner, skill, `tests/render-identity.py`, fixes to `isolated-window-smoke.py` and `editor-latency-live.py`), run in a disposable `git worktree` (`git rev-parse --show-toplevel` = the worktree).
- **Environment:** Omarchy, Hyprland 0.56.2, Quickshell 0.3.2, ImageMagick 7.1.2, Python 3.15, one 3840×2160 monitor at scale 1.6.
- **Clean run:** `scripts/verify.py --full`, run twice. Both times 28/28 passed in about 5.5 minutes (`render-identity`: 646 cases, 0 differ). Before this work the suite had one flaky check: `isolated-window` failed an exact color assert (229,76,115 against 230,76,116). After the fix it passed 5 of 5 runs.
- **Fault injection** (worktree only, then reverted):
  - Default highlight opacity 0.35 → 0.36 in `src/main.rs`: `render-golden` failed (case 7) and `render-identity` reported 17 differing cases. Both passed after the revert.
  - `undo()` turned into a no-op in `plugin/Editor.qml`: `editor-events`, `editor-objects`, `editor-background` and `editor-live` failed, each naming the undo assertion. They passed after the revert. The runner's `--why` mapped `plugin/Editor.qml` to the editor checks.
- **Runner probes:**
  - **Missing session:** without `WAYLAND_DISPLAY` → BLOCKED, exit 1.
  - **Timeout:** the process group was killed after the timeout.
  - **Interrupt:** SIGINT recorded `interrupted` with exit 1 and left nothing in the test's process session. SIGTERM is now handled the same way.
  - **Clipboard:** restored after the run.
  - **Unknown check or option:** exit 2. With no changes, the runner exits 2 instead of passing.
  - **`shell-current`:** passed against a matching install. Against the main tree (another session's uninstalled QML edits) it failed and named `Editor.qml`, `LiveScene.qml` and the binary.
- **Independent rehearsal:** a fresh agent was given only the worktree and the task "verify the colleague's highlight opacity 0.35 → 0.4 change".
  - It found the skill through `AGENTS.md` and ran `scripts/verify.py --why --keep`.
  - It correctly reported three failures: `render-golden`, `render-identity` and `live-scene-fidelity`.
  - It concluded the change must not be merged as is. Saved projects would re-render because highlight marks don't store their opacity, `LiveScene.qml` needs the same default, and the change needs a version.
  - It also found a verifier defect: `editor-latency` passed with empty results when the input never reached the window. The test now fails when any interaction goes unmeasured; this was confirmed failing once, then passing on an idle run and in the second full run.
- **Not run:** `shell-latency` and the install/restart recipe, which need the user's approval to install. Screenshots were not regenerated (no UI change). CI was not changed.
- **Status:** ready for the static, headless, identity and live routes on this machine. The real-shell route is partial: `shell-current` is proven, `shell-latency` has not been run through the runner here. It was used in earlier sessions without the runner.

## 2026-10-25: speed-up

- **Source:** 56e87b8 plus the parallel runner and the faster `live-scene-fidelity` (its exact renders now run in parallel while Quickshell grabs the live scenes, 40 s → 20 s). `render-identity` was already down to ~35 s in 56e87b8.
- **Result:** `scripts/verify.py --full` passed 28/28 three times, in 190 s, 163 s and 162 s, down from ~330 s run serially. `editor-latency` (~89 s, run alone) is now over half the wall time. It mostly waits for the backend's exact render to settle between steps.
- **Interrupt under parallel load:** a SIGTERM after 25 s killed the running checks, skipped the queued ones and reported NOT PASSED. No test processes were left behind.
- **Selection:** a `src/` change now selects 24 checks without the timing gates; `plugin/Editor.qml` still selects `editor-latency`.

## 2026-10-25: hidden live session

- **Change:** live checks run in a nested Hyprland (`Nested` in `scripts/verify.py`) instead of on the user's desktop; `--desktop` keeps the old behavior.
- **Result:** `scripts/verify.py --full` passed 28/28 with nothing shown on screen; `isolated-window` + `scroll` passed 3/3 repeated runs. `editor-latency` still passes the 50 ms p90 gate on the headless output.
- **Pitfalls found:** Hyprland's default open animations made `isolated-window` and `scroll` capture a still-growing window (nested config disables animations); creating the headless output and disabling `WAYLAND-1` right after raced, so the runner retries until only `HEADLESS-1` remains.

## 2026-10-25: parallel live sessions and pipelined builds

- **Change:** live checks run across up to 3 nested Hyprlands at once (`--sessions`) instead of one serial lane; the debug and release builds run side by side and checks start as soon as their own binary is ready instead of after both builds; offscreen checks run longest first in a pool of `--jobs` (CPU count, at most 8; was 5 lanes in total). `render-identity` caches the baseline binary per commit in `target/render-identity/omashot-<sha>` (last 4 kept), so repeated runs against the same `HEAD` skip the baseline build. `history-service` now lists its `magick` prerequisite (it failed instead of reporting BLOCKED without it).
- **Checked so far (cloud container without Hyprland, Quickshell or ImageMagick):** static checks and `install` pass in parallel and with `--serial`; checks without their tools report BLOCKED; debug and release builds ran concurrently without cargo lock waits; a SIGTERM during the release build killed it, skipped the check waiting on it and reported NOT PASSED.
- **Omarchy follow-up:** parallel live sessions and three full timed runs are recorded in the 2026-10-26 acceptance below.


## 2026-10-26: integrate PRs #1–#6 and fix review findings

- **Changes:** integrated parallel verification, combined recognition, remembered editor settings, scrolling robustness, the bar menu and Preferences shortcuts. Fixed missing skipped results and empty executor lanes, recognition cleanup status, fresh-image/background restoration and installer XDG isolation. Preferences and the bar now recognize Omarchy's opaque Lua callbacks by their generated descriptions; `keybindings-live` verifies registration and a Preferences save with real Omarchy helpers in a private Lua compositor.
- **Concurrency:** unrestricted ImageMagick pools multiplied the runner's pools and reproduced `editor-live`'s 60 s timeout, including without screenshot generation. The runner now defaults each ImageMagick process to one thread and render-identity to four workers. The headless editor passed all three final runs in 42.4, 40.3 and 43.5 s without changing its deadline or coverage.
- **Three full default runs:** 174.2 s → **32/32 PASS**; 169.9 s → **31 PASS, 1 FAIL** (`theme-live`: initial palette lag 27 ms vs the 25 ms gate); 177.8 s → **32/32 PASS**. The documented theme timing flake passed immediately when rerun alone (10.6 s check, no threshold change). No checks were blocked or skipped.
- **Render and latency:** all three runs passed 646 render-identity cases with zero differences and all 250 golden renders. Worst interaction p90 across the three editor-latency runs: 34 ms (50 ms gate). Live-scene fidelity, recognition success/failure cleanup, remembered backgrounds, final scrolling sample, bar shortcuts and installer isolation passed.
- **Screenshots:** regenerated all README screenshots in an isolated nested session from synthetic content; only `launcher.png` changed (combined recognition action), and it was visually inspected.
- **Scope:** no installation, shell restart or theme change in the user's real session. Installed-plugin behavior remains unverified; UI evidence above is from isolated compositors.
