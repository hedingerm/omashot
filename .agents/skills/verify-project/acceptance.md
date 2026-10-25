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
