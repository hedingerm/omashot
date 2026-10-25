# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The UI follows the active Omarchy theme live, including light themes. Inside the Omarchy shell it fades in step with the bar from the shell's own palette and holds the display frame rate. `OMASHOT_THEME_PATH` previews another theme directory.
- `themeStats` IPC call reports the frame pacing of the last theme fade.

### Changed

- The installer restarts the Omarchy shell when `qmldir` is new or a singleton such as `Theme.qml` changed, because singletons survive a plugin rescan.
- README screenshots are rendered in the Tokyo Night theme (`OMASHOT_SCREENSHOT_THEME` overrides it).

## [0.4.0] - 2026-10-25

First public release.

### Added

- Area, window, active window, fullscreen and repeat capture with frozen-desktop selection, magnifier and optional delay/cursor.
- Isolated window capture with alpha, scrolling capture (vertical and horizontal) and image import.
- Annotation editor: arrows, lines, shapes, text presets, numbered steps, pencil, highlight, spotlight, blur, redaction, pixelation, crop/rotate/flip and image layers, with undo/redo and editable projects.
- Background sidebar with twenty original backgrounds, wallpaper import, blur variants, plain colors, layout controls and saved presets.
- Quick-access thumbnails, pins, local OCR and QR recognition.
- History with configurable automatic expiry.
- Installer with ownership tracking, uninstaller, launcher, desktop entry and original OmaShot branding.

[Unreleased]: https://github.com/hedingerm/omashot/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/hedingerm/omashot/releases/tag/v0.4.0
