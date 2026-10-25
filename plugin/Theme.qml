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
    readonly property color sunken: mix(background, "#000000", 0.06 + 0.16 * (1 - luminance(background)))
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
    // Continuous rather than a threshold flip, so text on accent never snaps mid-fade.
    readonly property color accentText: mix(darkest, lightest, Math.max(0, Math.min(1, (0.45 - luminance(accent)) * 10 + 0.5)))
    readonly property color dangerSoft: mix(background, danger, 0.25)
    readonly property color darkest: luminance(foreground) < luminance(background) ? foreground : background
    readonly property color lightest: luminance(foreground) < luminance(background) ? background : foreground
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

    property string loaded: ""
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
        // Behaviors keep reading the old value mid-fade, so compare the incoming theme instead.
        // Inside omarchy-shell its palette wins: the shell may apply colors over IPC that differ from disk.
        var next = shell ? [shell.background.toString(), shell.foreground.toString(), shell.accent.toString(), shell.urgent.toString()] : [pick(["background", "color0"], background), pick(["foreground", "color7"], foreground), pick(["accent", "color4", "blue"], accent), pick(["red", "color1"], danger)];
        if (ready && next.join() !== loaded)
            trackFade();
        loaded = next.join();
        background = next[0];
        foreground = next[1];
        accent = next[2];
        danger = next[3];
        warning = pick(["yellow", "color3"], warning);
        success = pick(["green", "color2"], success);
        light = shell || !values.mode ? luminance(Qt.color(next[0])) > 0.5 : values.mode === "light";
        ready = true;
    }

    // Inside omarchy-shell, follow the shell's own palette so OmaShot fades in the same frame as
    // the bar (the shell applies themes over IPC, after theme.name is written). Standalone qs has
    // no qs.Commons; ShellPalette then fails to load and theme.name drives updates instead.
    property QtObject shell: null
    property Connections shellChanges: Connections {
        target: root.shell
        function onChanged() {
            root.load(root.colors.text());
            root.colors.reload(); // refresh yellow/green from the swapped theme dir
        }
    }

    // Frame pacing of the last fade, for `qs ipc call omashot themeStats`.
    property var fade: ({})
    property var fadeGaps: []
    property real fadeStart: 0
    property real fadeLast: 0
    function trackFade() {
        fadeGaps = [];
        fadeLast = 0;
        fadeStart = Date.now();
        fadeTimer.restart();
    }
    property FrameAnimation fadeFrames: FrameAnimation {
        running: root.fadeTimer.running
        onTriggered: {
            var now = Date.now();
            if (root.fadeLast)
                root.fadeGaps.push(now - root.fadeLast);
            root.fadeLast = now;
        }
    }
    property Timer fadeTimer: Timer {
        interval: root.duration + 60
        onTriggered: {
            var g = root.fadeGaps.slice().sort(function (a, b) {
                return a - b;
            });
            root.fade = {
                frames: g.length,
                medianMs: g.length ? g[g.length >> 1] : 0,
                worstMs: g.length ? g[g.length - 1] : 0,
                source: root.shell ? "omarchy-shell" : "theme.name"
            };
        }
    }

    // Read synchronously on creation so windows never open with the fallback palette.
    Component.onCompleted: {
        var probe = Qt.createComponent(Qt.resolvedUrl("ShellPalette.qml"), Component.PreferSynchronous);
        if (probe.status === Component.Ready)
            shell = probe.createObject(root);
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
        watchChanges: !root.shell
        printErrors: false
        onFileChanged: root.colors.reload()
    }
}
