pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Live Omarchy palette. `omarchy theme set` swaps current/theme and then rewrites
// theme.name, so watching that file is enough to follow every switch. Base colors
// animate like omarchy-shell (420 ms InOutCubic); every role derives from them.
QtObject {
    id: root
    readonly property string statePath: Quickshell.env("OMASHOT_THEME_PATH") || (Quickshell.env("HOME") + "/.local/state/omarchy/current")
    property bool ready: false
    property bool light: false

    property color background: "#15171f"
    property color foreground: "#e8e6f3"
    property color accent: "#9d8bf3"
    property color danger: "#f07a8f"
    property color warning: "#f4c66a"
    property color success: "#8de2a1"
    readonly property int duration: 420
    Behavior on background { enabled: root.ready; ColorAnimation { duration: root.duration; easing.type: Easing.InOutCubic } }
    Behavior on foreground { enabled: root.ready; ColorAnimation { duration: root.duration; easing.type: Easing.InOutCubic } }
    Behavior on accent { enabled: root.ready; ColorAnimation { duration: root.duration; easing.type: Easing.InOutCubic } }
    Behavior on danger { enabled: root.ready; ColorAnimation { duration: root.duration; easing.type: Easing.InOutCubic } }
    Behavior on warning { enabled: root.ready; ColorAnimation { duration: root.duration; easing.type: Easing.InOutCubic } }
    Behavior on success { enabled: root.ready; ColorAnimation { duration: root.duration; easing.type: Easing.InOutCubic } }

    // Surfaces step from background toward foreground, so light themes work unchanged.
    readonly property color window: background
    readonly property color sunken: mix(background, "#000000", light ? 0.06 : 0.22)
    readonly property color panel: mix(background, foreground, 0.045)
    readonly property color surface: mix(background, foreground, 0.085)
    readonly property color raised: mix(background, foreground, 0.14)
    readonly property color border: mix(background, foreground, 0.17)
    readonly property color borderStrong: mix(background, foreground, 0.32)
    readonly property color text: foreground
    readonly property color textSoft: mix(foreground, background, 0.2)
    readonly property color textMuted: mix(foreground, background, 0.42)
    readonly property color textDisabled: mix(foreground, background, 0.6)
    readonly property color accentHover: mix(accent, foreground, 0.2)
    readonly property color accentPressed: mix(accent, background, 0.22)
    readonly property color accentSoft: mix(background, accent, 0.22)
    readonly property color accentText: luminance(accent) > 0.45 ? darkest : lightest
    readonly property color dangerSoft: mix(background, danger, 0.25)
    readonly property color darkest: light ? foreground : background
    readonly property color lightest: light ? background : foreground
    readonly property color scrim: alpha(background, 0.5)

    // Fusion palette for Qt Quick Controls. Assign with `palette: Theme.controls.palette`
    // on each window's root item and on every Popup/Menu/Dialog (popups don't inherit).
    // Roles animate on a private staging item; `controls` takes the whole palette once per
    // tick, because each role change otherwise re-propagates through every control (~15 fps).
    property Item controls: Item {}
    function publishPalette() {
        controls.palette = staging.palette;
    }
    // Text roles set active/inactive/disabled separately; a plain role would overwrite all groups.
    property Item staging: Item {
        onPaletteChanged: Qt.callLater(root.publishPalette)
        palette.window: root.panel
        palette.base: root.surface
        palette.alternateBase: root.raised
        palette.button: root.surface
        palette.light: root.raised
        palette.midlight: root.raised
        palette.mid: root.border
        palette.dark: root.borderStrong
        palette.shadow: root.alpha(root.darkest, 0.5)
        palette.highlight: root.accent
        palette.highlightedText: root.accentText
        palette.brightText: root.lightest
        palette.link: root.accent
        palette.toolTipBase: root.window
        palette.toolTipText: root.text
        palette.active.windowText: root.text
        palette.inactive.windowText: root.text
        palette.disabled.windowText: root.textDisabled
        palette.active.text: root.text
        palette.inactive.text: root.text
        palette.disabled.text: root.textDisabled
        palette.active.buttonText: root.text
        palette.inactive.buttonText: root.text
        palette.disabled.buttonText: root.textDisabled
        palette.active.placeholderText: root.textMuted
        palette.inactive.placeholderText: root.textMuted
        palette.disabled.placeholderText: root.textDisabled
    }

    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t);
    }
    function alpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, c.a * a);
    }
    function luminance(c) {
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    }

    function load(raw) {
        var values = {};
        String(raw || "").split("\n").forEach(function (line) {
            var m = line.match(/^\s*([A-Za-z0-9_]+)\s*=\s*["']([^"']*)["']/);
            if (m)
                values[m[1]] = m[2];
        });
        function pick(keys, fallback) {
            for (var i = 0; i < keys.length; i++)
                if (/^#[0-9a-fA-F]{6}$/.test(values[keys[i]] || ""))
                    return values[keys[i]];
            return fallback;
        }
        background = pick(["background", "color0"], background);
        foreground = pick(["foreground", "color7"], foreground);
        accent = pick(["accent", "color4", "blue"], accent);
        danger = pick(["red", "color1"], danger);
        warning = pick(["yellow", "color3"], warning);
        success = pick(["green", "color2"], success);
        light = values.mode ? values.mode === "light" : luminance(Qt.color(background)) > 0.5;
        ready = true;
    }

    // Read synchronously on creation so windows never open with the fallback palette.
    Component.onCompleted: {
        load(colors.text());
        publishPalette();
    }
    property FileView colors: FileView {
        path: root.statePath + "/theme/colors.toml"
        blockLoading: true
        printErrors: false
        onLoaded: root.load(text())
    }
    property FileView themeName: FileView {
        path: root.statePath + "/theme.name"
        watchChanges: true
        printErrors: false
        onFileChanged: root.colors.reload()
    }
}
