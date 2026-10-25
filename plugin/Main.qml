import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Dialogs
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Item {
    id: root
    property var shell: null
    property var manifest: null
    property string backend: Quickshell.env("OMASHOT_BACKEND") || (Quickshell.env("HOME") + "/.local/bin/omashot")
    property var preferences: ({})
    property bool capturing: false
    property bool opened: false
    property bool editing: false
    property bool quickOpened: false
    property var quickCaptures: []
    property int quickCounter: 0
    property string exportSource: ""
    property var captureActionQueue: []
    property string historyFilter: ""
    property string current: ""
    property string status: "Ready"
    property var captures: []
    property var pins: []
    property int pinCounter: 0
    property bool showHistory: false
    property real previewZoom: 0
    property string job: ""
    property var pendingPreferences: null
    property string pendingPreferencesJob: "settings-save"
    property string scrollSession: ""
    property string scrollGeometryHint: ""
    property bool horizontalScroll: false
    property int delay: 0
    property bool cursor: false
    property string pendingMode: ""
    property bool preferencesLoaded: false
    property var captureSnapshot: null
    property string recognitionPath: ""
    property var shortcutInfo: ({})
    property var shortcutDraft: ({})
    property var pendingShortcuts: null
    Binding {
        target: Theme
        property: "corners"
        value: root.preferences.corners || "auto"
    }
    function open(payload) {
        if (scrollSurface.active)
            return;
        quickOpened = false;
        opened = true;
        run(["config"], "config-load");
    }
    function close() {
        opened = false;
    }
    function toggle() {
        if (opened)
            close();
        else
            open("{}");
    }
    function run(args, purpose) {
        if (worker.running) {
            status = "Wait for the current operation";
            return false;
        }
        job = purpose || args[0];
        status = "Working…";
        worker.command = [backend].concat(args);
        worker.running = true;
        return true;
    }
    function savePreferences(value, purpose) {
        pendingPreferences = value;
        pendingPreferencesJob = purpose || "settings-save";
        preferencesSaveTimer.restart();
    }
    Timer {
        id: preferencesSaveTimer
        interval: 80
        onTriggered: {
            if (worker.running) {
                restart();
                return;
            }
            if (root.pendingPreferences !== null) {
                let value = root.pendingPreferences;
                root.pendingPreferences = null;
                root.run(["config", JSON.stringify(value)], root.pendingPreferencesJob);
            }
        }
    }
    // Shortcut chords mirror the backend's canonical form: modifiers in SUPER, CTRL, ALT, SHIFT order, then the key.
    function normalizeChord(text) {
        let parts = String(text || "").split("+").map(function (p) {
            return p.trim();
        });
        if (parts.length === 1 && !parts[0])
            return "";
        let key = parts.pop();
        let names = {
            SUPER: "SUPER", WIN: "SUPER", LOGO: "SUPER", META: "SUPER", MOD4: "SUPER",
            CTRL: "CTRL", CONTROL: "CTRL", ALT: "ALT", MOD1: "ALT", SHIFT: "SHIFT"
        };
        let mods = parts.map(function (m) {
            return names[m.toUpperCase()];
        });
        if (parts.length > 4 || mods.indexOf(undefined) >= 0 || !/^([A-Za-z0-9_]{1,32}|code:[0-9]{1,3})$/.test(key) || names[key.toUpperCase()])
            return null;
        return ["SUPER", "CTRL", "ALT", "SHIFT"].filter(function (m) {
            return mods.indexOf(m) >= 0;
        }).concat([key.length === 1 ? key.toUpperCase() : key]).join(" + ");
    }
    // Chord for a key event, or "" when the event should stay ordinary typing.
    function eventChord(event) {
        let k = event.key;
        let special = {};
        special[Qt.Key_Print] = "Print";
        special[Qt.Key_Space] = "SPACE";
        special[Qt.Key_Return] = "RETURN";
        special[Qt.Key_Tab] = "TAB";
        special[Qt.Key_Home] = "Home";
        special[Qt.Key_End] = "End";
        special[Qt.Key_Insert] = "Insert";
        special[Qt.Key_Delete] = "Delete";
        special[Qt.Key_PageUp] = "Page_Up";
        special[Qt.Key_PageDown] = "Page_Down";
        special[Qt.Key_Up] = "Up";
        special[Qt.Key_Down] = "Down";
        special[Qt.Key_Left] = "Left";
        special[Qt.Key_Right] = "Right";
        special[Qt.Key_Minus] = "minus";
        special[Qt.Key_Equal] = "equal";
        special[Qt.Key_Comma] = "comma";
        special[Qt.Key_Period] = "period";
        special[Qt.Key_Slash] = "slash";
        let held = event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier);
        let key = (k >= Qt.Key_A && k <= Qt.Key_Z) || (k >= Qt.Key_0 && k <= Qt.Key_9) ? String.fromCharCode(k) : k >= Qt.Key_F1 && k <= Qt.Key_F35 ? "F" + (k - Qt.Key_F1 + 1) : special[k] || "";
        // Plain text keys (and Delete/arrows without modifiers) keep editing the field.
        if (!key || (!held && (key.length === 1 || ["Delete", "Home", "End", "Left", "Right", "Up", "Down", "TAB", "RETURN", "SPACE", "minus", "equal", "comma", "period", "slash"].indexOf(key) >= 0)))
            return "";
        return [[Qt.MetaModifier, "SUPER"], [Qt.ControlModifier, "CTRL"], [Qt.AltModifier, "ALT"], [Qt.ShiftModifier, "SHIFT"]].filter(function (m) {
            return event.modifiers & m[0];
        }).map(function (m) {
            return m[1];
        }).concat([key]).join(" + ");
    }
    function shortcutNote(id, text) {
        let keys = normalizeChord(text);
        if (keys === null)
            return "Not a valid shortcut";
        if (!keys)
            return "";
        let same = function (a) {
            return String(a || "").toLowerCase() === keys.toLowerCase();
        };
        for (let other in shortcutDraft)
            if (other !== id && same(normalizeChord(shortcutDraft[other])))
                return "Also used for " + ((shortcutInfo.actions || []).find(function (a) {
                        return a.id === other;
                    }) || {
                        label: other
                    }).label;
        let hit = (shortcutInfo.taken || []).find(function (b) {
            return same(b.keys);
        });
        if (hit)
            return "Replaces " + (hit.description || hit.command);
        if (shortcutInfo.replaced && shortcutInfo.replaced[id] && same((shortcutInfo.bindings || {})[id]))
            return "Replaces " + shortcutInfo.replaced[id];
        return "";
    }
    function saveShortcuts() {
        let wanted = {};
        let saved = shortcutInfo.bindings || {};
        let changed = false;
        for (let id in shortcutDraft) {
            let keys = normalizeChord(shortcutDraft[id]);
            if (keys === null) {
                status = "Shortcut not saved: " + shortcutDraft[id] + " is not a valid shortcut";
                return;
            }
            if (keys)
                wanted[id] = keys;
        }
        for (let id of Object.keys(wanted).concat(Object.keys(saved)))
            changed = changed || wanted[id] !== saved[id];
        // After a reinstall the choice is still saved but no longer hooked into Hyprland.
        changed = changed || (!shortcutInfo.installed && Object.keys(wanted).length > 0);
        if (!changed || !shortcutInfo.available)
            return;
        pendingShortcuts = wanted;
        shortcutsSaveTimer.restart();
    }
    Timer {
        id: shortcutsSaveTimer
        interval: 80
        onTriggered: {
            if (worker.running || preferencesSaveTimer.running || root.pendingPreferences !== null) {
                restart();
                return;
            }
            if (root.pendingShortcuts !== null) {
                let value = root.pendingShortcuts;
                root.pendingShortcuts = null;
                root.run(["bindings", "set", JSON.stringify(value)], "bindings-save");
            }
        }
    }
    function refresh() {
        if (worker.running)
            historyRefreshTimer.restart();
        else
            run(["history"], "history");
    }
    Timer {
        id: historyRefreshTimer
        interval: 100
        onTriggered: root.refresh()
    }
    function capture(mode) {
        if (scrollSurface.active) {
            root.status = "Finish or cancel scrolling capture first";
            return;
        }
        captureTimer.interval = hideDelay();
        opened = false;
        quickOpened = false;
        capturing = true;
        pendingMode = mode;
        captureTimer.start();
    }
    // Our own surfaces need a moment to unmap before grim runs; skip the wait when none is shown.
    function hideDelay() {
        return opened || quickOpened || selector.opened || (pins.length && !scrollSurface.active) ? 350 : 0;
    }
    function beginScrolling(geometry) {
        if (scrollSurface.active)
            return;
        captureTimer.interval = hideDelay();
        opened = false;
        quickOpened = false;
        capturing = true;
        pendingMode = "scroll";
        if (!geometry) {
            captureTimer.restart();
            return;
        }
        scrollGeometryHint = geometry;
        scrollTimer.restart();
    }
    function startScrollSampling() {
        scrollSurface.begin();
    }
    function finishScrolling() {
        scrollSurface.requestFinish();
    }
    function cancelScrolling() {
        scrollSurface.requestCancel();
    }
    function beginEditing() {
        if (scrollSurface.active)
            return;
        root.quickOpened = false;
        root.opened = true;
        root.showHistory = false;
        root.editing = true;
    }
    function dateLabel(t) {
        return new Date(Number(t) * 1000).toLocaleString(Qt.locale(), "dd MMM · HH:mm");
    }
    function unlockPins() {
        for (let i = 0; i < pinSurfaces.instances.length; i++)
            pinSurfaces.instances[i].clickThrough = false;
    }
    function pin(path) {
        let target = path || current;
        if (target) {
            pinCounter++;
            let known = captures.concat(quickCaptures).find(function (c) {
                return c.path === target;
            }) || {};
            pins = pins.concat([
                {
                    path: target,
                    id: pinCounter,
                    width: known.width || 0
                }
            ]);
        }
    }
    function restoreQuickCapture(data) {
        current = data.path;
        editing = false;
        opened = false;
        showHistory = false;
        quickCounter++;
        quickCaptures = [
            {
                id: quickCounter,
                path: data.path,
                width: data.width,
                height: data.height
            }
        ].concat(quickCaptures.filter(function (c) {
            return c.path !== data.path;
        }));
        quickOpened = true;
        quickAccess.restore();
    }
    function dismissQuick(id) {
        quickCaptures = quickCaptures.filter(function (c) {
            return c.id !== id;
        });
        if (!quickCaptures.length)
            quickOpened = false;
    }
    function queueCaptureAction(args, purpose) {
        captureActionQueue = captureActionQueue.concat([
            {
                args: args,
                purpose: purpose
            }
        ]);
        captureActionTimer.restart();
    }
    Timer {
        id: captureActionTimer
        interval: 80
        onTriggered: {
            if (worker.running) {
                restart();
                return;
            }
            if (root.captureActionQueue.length) {
                let action = root.captureActionQueue[0];
                root.captureActionQueue = root.captureActionQueue.slice(1);
                root.run(action.args, action.purpose);
            }
        }
    }
    function receiveCapture(data) {
        current = data.path;
        editing = false;
        opened = false;
        if (preferences.show_overlay !== false) {
            quickCounter++;
            quickCaptures = [
                {
                    id: quickCounter,
                    path: data.path,
                    width: data.width,
                    height: data.height
                }
            ].concat(quickCaptures).slice(0, 20);
            quickAccess.restore();
            quickOpened = true;
        } else
            quickOpened = false;
        if (preferences.copy_after_capture)
            queueCaptureAction(["copy", data.path], "post-copy");
        if (preferences.save_after_capture && preferences.export_directory) {
            let destination = String(preferences.export_directory).replace(/\/$/, "") + "/" + data.path.split("/").pop();
            queueCaptureAction(["export", data.path, destination], "post-save");
        }
        if (preferences.pin_after_capture)
            pin(data.path);
        if (preferences.annotate_after_capture)
            beginEditing();
    }
    function finishFrozenSelection(geometry) {
        selector.opened = false;
        if (!captureSnapshot || !captureSnapshot.path)
            return;
        let mode = pendingMode;
        if (mode === "scroll") {
            queueCaptureAction(["snapshot-cancel", captureSnapshot.path], "post-snapshot-cancel");
            captureSnapshot = null;
            beginScrolling(geometry);
            return;
        }
        root.run(["capture-frozen", captureSnapshot.path, geometry], mode === "ocr" || mode === "qr" ? "recognition-capture" : "capture");
        captureSnapshot = null;
    }
    function cancelFrozenSelection() {
        selector.opened = false;
        if (captureSnapshot && captureSnapshot.path)
            root.queueCaptureAction(["snapshot-cancel", captureSnapshot.path], "post-snapshot-cancel");
        captureSnapshot = null;
        capturing = false;
        quickOpened = !!quickCaptures.length;
        status = "Done";
    }
    component Action: IconButton {
        iconName: ({
                "Copy": "copy",
                "Save": "save",
                "Save as…": "save",
                "Pin": "pin",
                "Annotate": "text",
                "History": "history",
                "×": "close",
                "−": "minus",
                "+": "plus",
                "Pass through": "drag"
            })[text] || "more"
    }
    Timer {
        id: captureTimer
        interval: 350
        onTriggered: {
            if (worker.running) {
                interval = 50;
                restart();
                return;
            }
            if (!root.preferencesLoaded) {
                root.run(["config"], "capture-config");
                return;
            }
            root.opened = false;
            root.quickOpened = false;
            root.capturing = true;
            if ((root.pendingMode === "region" && root.preferences.freeze_capture !== false) || root.pendingMode === "ocr" || root.pendingMode === "qr" || root.pendingMode === "scroll") {
                root.run(["snapshot", "--delay", String(root.delay)].concat(root.cursor ? ["--cursor"] : []), "snapshot");
            } else
                root.run(["capture", root.pendingMode, "--delay", String(root.delay)].concat(root.cursor ? ["--cursor"] : []), "capture");
        }
    }
    Process {
        id: worker
        property string result: ""
        property string err: ""
        stdout: StdioCollector {
            onStreamFinished: worker.result = text
        }
        stderr: StdioCollector {
            onStreamFinished: worker.err = text
        }
        onStarted: {
            result = "";
            err = "";
        }
        onExited: function (code) {
            if (root.job === "capture" || root.job === "recognition-capture" || root.job.startsWith("scroll-"))
                root.capturing = false;
            var data;
            try {
                data = JSON.parse(result);
            } catch (e) {
                data = {
                    error: err || result || "Command failed"
                };
            }
            if (root.job.startsWith("post-") && root.captureActionQueue.length)
                captureActionTimer.restart();
            if (code !== 0 || data.error) {
                if (root.job === "snapshot")
                    root.capturing = false;
                if (root.job === "bindings-load")
                    settings.open();
                root.status = data.error || err;
                root.opened = true;
                return;
            }
            root.status = "Done";
            if (root.captureActionQueue.length)
                captureActionTimer.restart();
            if (root.job === "post-quick-copy")
                quickAccess.confirmCopy();
            if (root.job.startsWith("post-"))
                return;
            if (root.job === "export") {
                root.exportSource = "";
                return;
            }
            if (root.job === "snapshot") {
                root.captureSnapshot = data;
                selector.snapshot = data;
                selector.opened = true;
                return;
            }
            if (root.job === "recognition-capture") {
                root.recognitionPath = data.path;
                let kind = root.pendingMode;
                Qt.callLater(function () {
                    root.run([kind, data.path], "direct-" + kind);
                });
                return;
            }
            if (root.job === "direct-ocr" || root.job === "direct-qr") {
                root.capturing = false;
                root.opened = false;
                root.quickOpened = !!root.quickCaptures.length;
                root.queueCaptureAction(["delete", root.recognitionPath], "post-recognition-cleanup");
                root.recognitionPath = "";
                Quickshell.execDetached(["notify-send", "--expire-time=1800", "OmaShot", root.job === "direct-qr" ? "QR code copied to clipboard" : data.text ? "Text copied to clipboard" : "No text found"]);
                return;
            }
            if (root.job === "capture-config") {
                root.preferences = data;
                root.preferencesLoaded = true;
                root.delay = data.delay || 0;
                root.cursor = !!data.cursor;
                captureTimer.restart();
                return;
            }
            if (root.job === "config-load") {
                root.preferencesLoaded = true;
                root.preferences = data;
                root.delay = data.delay || 0;
                root.cursor = !!data.cursor;
                Qt.callLater(root.refresh);
            } else if (root.job === "history") {
                // Keep the same model when nothing changed so history tiles are not recreated.
                if (JSON.stringify(data) !== JSON.stringify(root.captures))
                    root.captures = data;
                root.quickCaptures = root.quickCaptures.filter(function (c) {
                    return data.some(function (h) {
                        return h.path === c.path;
                    });
                });
                if (!root.quickCaptures.length)
                    root.quickOpened = false;
                if (root.current && !root.scrollSession && !root.editing && !data.some(function (c) {
                    return c.path === root.current;
                }))
                    root.current = "";
            } else if (root.job === "config") {
                root.preferences = data;
                prefDelay.value = data.delay || 0;
                prefCursor.checked = !!data.cursor;
                prefRetention.value = data.retention_days === undefined ? 30 : data.retention_days;
                prefFormat.currentIndex = ["png", "jpeg", "webp"].indexOf(data.format || "png");
                prefLanguage.text = data.ocr_language || "eng";
                prefTimeout.value = data.overlay_timeout || 0;
                prefPosition.currentIndex = ["bottom-right", "bottom-left", "top-right", "top-left"].indexOf(data.overlay_position || "bottom-right");
                prefShowOverlay.checked = data.show_overlay !== false;
                prefAutoCopy.checked = !!data.copy_after_capture;
                prefAutoSave.checked = !!data.save_after_capture;
                prefAutoEdit.checked = !!data.annotate_after_capture;
                prefAutoPin.checked = !!data.pin_after_capture;
                prefExportDirectory.text = data.export_directory || "";
                prefOverlaySize.value = data.overlay_size || 240;
                prefOverlayScreen.currentIndex = Math.max(0, prefOverlayScreen.model.indexOf(data.overlay_screen || "active"));
                prefDismissDrop.checked = data.dismiss_after_drop !== false;
                prefFreeze.checked = data.freeze_capture !== false;
                prefCrosshair.checked = data.show_crosshair !== false;
                prefMagnifier.checked = data.show_magnifier !== false;
                prefWindowTransparent.checked = !!data.window_transparent;
                prefCorners.currentIndex = Math.max(0, ["auto", "square", "rounded"].indexOf(data.corners || "auto"));
                Qt.callLater(function () {
                    root.run(["bindings"], "bindings-load");
                });
            } else if (root.job === "bindings-load") {
                root.shortcutDraft = Object.assign({}, data.bindings || {});
                root.shortcutInfo = data;
                settings.open();
            } else if (root.job === "bindings-save") {
                root.shortcutInfo = data;
                if (data.missing && data.missing.length)
                    root.status = "Hyprland did not register shortcuts for: " + data.missing.join(", ") + (data.configErrors ? " (" + data.configErrors + ")" : "");
                else if (!data.reloaded)
                    root.status = "Shortcuts saved; they apply after Hyprland reloads";
                else
                    root.status = "Shortcuts applied";
            } else if (root.job === "ocr" || root.job === "qr") {
                outputText.text = data.text || data.value || JSON.stringify(data);
                output.open();
            } else if (root.job === "scroll-cancel") {
                root.scrollSession = "";
                root.status = "Scrolling capture cancelled";
            } else if (root.job === "scroll-start") {
                root.scrollSession = data.session;
                root.capturing = true;
                root.opened = false;
                root.quickOpened = false;
                scrollSurface.start(data.session, data.geometry);
                root.status = "Done";
            } else if (data.path) {
                if (root.job === "scroll-finish")
                    root.scrollSession = "";
                root.current = data.path;
                root.editing = false;
                if (root.job === "capture") {
                    root.receiveCapture(data);
                } else
                    root.opened = true;
            } else if (root.job === "delete" || root.job === "settings-save")
                Qt.callLater(root.refresh);
        }
    }
    IpcHandler {
        target: "omashot"
        function open(): void {
            root.open("{}");
        }
        function capture(mode: string): void {
            root.capture(mode || "region");
        }
        function status(): string {
            return JSON.stringify({
                opened: root.opened,
                quickOpened: root.quickOpened,
                current: root.current,
                status: root.status,
                editing: root.editing,
                pins: root.pins.length,
                quickCount: root.quickCaptures.length,
                quickCollapsed: quickAccess.collapsed,
                scrollActive: scrollSurface.active,
                scrollPolling: scrollSurface.polling,
                selecting: selector.opened,
                scrollPreviewReady: scrollSurface.previewReady,
                scrollWidth: scrollSurface.capturedWidth,
                scrollHeight: scrollSurface.capturedHeight
            });
        }
        function themeStats(): string {
            return JSON.stringify(Theme.fade);
        }
        function measureFrames(ms: int): void {
            Theme.measure(Math.max(100, Math.min(10000, ms)), "probe");
        }
        // Editor latency probe for live tests: geometry of a named item, tool/operation setup, and per-input stats.
        function editorLatency(): string {
            return JSON.stringify(editor.latencyStats());
        }
        function editorLatencyReset(): void {
            editor.probeSamples = {};
            editor.probeInputs = [];
            editor.probing = true;
        }
        function editorRect(name: string): string {
            return JSON.stringify(editor.probeRect(name));
        }
        // `operations` is base64 JSON: qs ipc splits plain string arguments.
        function editorSetup(tool: string, operations: string): void {
            editor.tool = tool;
            if (operations)
                editor.commit(JSON.parse(Qt.atob(operations)), "draw");
        }
        function annotate(): void {
            root.beginEditing();
        }
        function pin(): void {
            root.pin();
        }
        function dismiss(): void {
            root.close();
            root.quickOpened = false;
        }
        function expand(): void {
            if (scrollSurface.active)
                return;
            root.opened = true;
            window.fullscreen = !window.fullscreen;
        }
        function restoreOverlay(): void {
            root.quickOpened = !!root.quickCaptures.length;
            quickAccess.restore();
        }
        function hideOverlays(): void {
            quickAccess.hideTemporarily();
        }
        function preferences(): void {
            if (scrollSurface.active)
                return;
            root.opened = true;
            root.run(["config"], "config");
        }
        function history(): void {
            root.showHistory = true;
            root.open("{}");
        }
        function importImage(path: string): void {
            if (scrollSurface.active)
                return;
            root.run(["import", path], "import");
        }
    }
    FileDialog {
        id: importer
        title: "Open image"
        nameFilters: ["Images (*.png *.jpg *.jpeg *.webp)"]
        onAccepted: root.run(["import", decodeURIComponent(String(selectedFile).replace("file://", ""))], "import")
    }
    FileDialog {
        id: exporter
        title: "Save screenshot"
        fileMode: FileDialog.SaveFile
        nameFilters: ["PNG (*.png)", "JPEG (*.jpg)", "WebP (*.webp)"]
        onAccepted: root.run(["export", root.exportSource || root.current, decodeURIComponent(String(selectedFile).replace("file://", ""))], "export")
    }
    FolderDialog {
        id: exportFolder
        title: "Choose screenshot export directory"
        onAccepted: prefExportDirectory.text = decodeURIComponent(selectedFolder.toString().replace(/^file:\/\//, ""))
    }
    FloatingWindow {
        id: window
        visible: root.opened
        title: "OmaShot"
        implicitWidth: 1220
        implicitHeight: 850
        minimumSize: Qt.size(760, 560)
        color: Theme.window
        onClosed: root.close()
        Shortcut {
            sequence: "Escape"
            onActivated: {
                if (root.editing && editor.cancelActiveMode())
                    return;
                if (window.fullscreen)
                    window.fullscreen = false;
                else if (root.editing)
                    cancelEdits.open();
                else
                    root.close();
            }
        }
        ColumnLayout {
            id: windowContent
            anchors.fill: parent
            spacing: 0
            palette: Theme.controls.palette
            // Popups and the shared ToolTip don't inherit item palettes.
            Binding {
                target: windowContent.ToolTip.toolTip
                property: "palette"
                value: Theme.controls.palette
            }
            Rectangle {
                visible: !root.editing
                Layout.fillWidth: true
                implicitHeight: 58
                color: Theme.panel
                Flickable {
                    id: topStrip
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    contentWidth: topRow.width
                    contentHeight: height
                    clip: true
                    ScrollBar.horizontal: ScrollBar {
                        policy: ScrollBar.AsNeeded
                    }
                    RowLayout {
                        id: topRow
                        width: Math.max(implicitWidth, topStrip.width)
                        height: topStrip.height
                        spacing: 5
                        Image {
                            source: "assets/brand/omashot-mark.svg"
                            sourceSize.width: 64
                            sourceSize.height: 64
                            Layout.preferredWidth: 30
                            Layout.preferredHeight: 30
                            fillMode: Image.PreserveAspectFit
                        }
                        Label {
                            text: "OmaShot"
                            font.pixelSize: 16
                            font.weight: Font.DemiBold
                            color: Theme.text
                            rightPadding: 16
                        }
                        IconButton {
                            iconName: "capture"
                            text: "Capture area"
                            onClicked: root.capture("region")
                        }
                        IconButton {
                            iconName: "window"
                            text: "Capture window"
                            onClicked: root.capture("window")
                        }
                        IconButton {
                            iconName: "screen"
                            text: "Capture full screen"
                            onClicked: root.capture("fullscreen")
                        }
                        IconButton {
                            iconName: "reset"
                            text: "Repeat last area"
                            onClicked: root.capture("repeat")
                        }
                        IconButton {
                            iconName: "clock"
                            text: root.delay ? "Delay: " + root.delay + " seconds" : "Capture options"
                            selected: root.delay > 0 || root.cursor
                            onClicked: captureOptions.open()
                        }
                        IconButton {
                            iconName: "ocr"
                            text: "Capture text"
                            onClicked: root.capture("ocr")
                        }
                        IconButton {
                            iconName: "qr"
                            text: "Read QR from screen"
                            onClicked: root.capture("qr")
                        }
                        Rectangle {
                            implicitWidth: 1
                            implicitHeight: 22
                            color: Theme.border
                            Layout.leftMargin: 7
                            Layout.rightMargin: 7
                        }
                        IconButton {
                            iconName: "resize"
                            text: "Scrolling capture"
                            selected: !!root.scrollSession
                            onClicked: {
                                root.beginScrolling("");
                            }
                        }
                        IconButton {
                            iconName: "check"
                            text: "Finish scrolling capture"
                            visible: !!root.scrollSession
                            onClicked: root.run(["scroll", "finish", root.scrollSession], "scroll-finish")
                        }
                        IconButton {
                            iconName: "close"
                            text: "Cancel scrolling capture"
                            visible: !!root.scrollSession
                            onClicked: root.run(["scroll", "cancel", root.scrollSession], "scroll-cancel")
                        }
                        Item {
                            Layout.fillWidth: true
                        }
                        BusyIndicator {
                            implicitWidth: 24
                            implicitHeight: 24
                            running: worker.running
                            visible: running
                        }
                        IconButton {
                            iconName: "import"
                            text: "Open image"
                            onClicked: importer.open()
                        }
                        IconButton {
                            iconName: "history"
                            text: "History"
                            selected: root.showHistory
                            onClicked: {
                                root.showHistory = !root.showHistory;
                                root.refresh();
                            }
                        }
                        IconButton {
                            iconName: "pin"
                            text: "Pinned screenshot controls"
                            visible: root.pins.length > 0
                            onClicked: pinsMenu.open()
                        }
                        IconButton {
                            iconName: "settings"
                            text: "Preferences"
                            onClicked: root.run(["config"], "config")
                        }
                        IconButton {
                            iconName: "expand"
                            text: "Expand / restore"
                            onClicked: window.fullscreen = !window.fullscreen
                        }
                        IconButton {
                            iconName: "close"
                            text: "Close"
                            onClicked: root.close()
                        }
                    }
                }
            }
            Rectangle {
                visible: !root.editing
                Layout.fillWidth: true
                implicitHeight: 1
                color: Theme.border
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0
                Rectangle {
                    visible: root.showHistory
                    Layout.preferredWidth: Math.min(226, window.width * 0.35)
                    Layout.fillHeight: true
                    color: Theme.panel
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 12
                        RowLayout {
                            Label {
                                text: "History"
                                font.pixelSize: 15
                                font.weight: Font.DemiBold
                                color: Theme.text
                                Layout.fillWidth: true
                            }
                            Label {
                                text: String(root.captures.length)
                                font.pixelSize: 12
                                color: Theme.textMuted
                            }
                        }
                        TextField {
                            Layout.fillWidth: true
                            placeholderText: "Search captures"
                            font.pixelSize: 12
                            onTextChanged: root.historyFilter = text
                        }
                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            spacing: 10
                            model: root.captures.filter(function (c) {
                                return !root.historyFilter || (root.dateLabel(c.modified) + " " + c.path).toLowerCase().includes(root.historyFilter.toLowerCase());
                            })
                            ScrollBar.vertical: ScrollBar {}
                            delegate: ItemDelegate {
                                id: historyCard
                                required property var modelData
                                width: ListView.view.width
                                height: 169
                                onClicked: {
                                    root.current = modelData.path;
                                    root.editing = false;
                                    root.previewZoom = 0;
                                }
                                background: Rectangle {
                                    radius: Theme.radius(9)
                                    color: root.current === modelData.path ? Theme.accentSoft : Theme.surface
                                    border.color: root.current === modelData.path ? Theme.accent : Theme.border
                                }
                                contentItem: ColumnLayout {
                                    spacing: 7
                                    Image {
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        source: "file://" + modelData.path
                                        fillMode: Image.PreserveAspectFit
                                        asynchronous: true
                                        sourceSize.width: 360
                                    }
                                    RowLayout {
                                        Label {
                                            text: root.dateLabel(modelData.modified)
                                            font.pixelSize: 11
                                            color: Theme.textSoft
                                            Layout.fillWidth: true
                                        }
                                        Label {
                                            text: modelData.width + "×" + modelData.height
                                            font.pixelSize: 10
                                            color: Theme.textMuted
                                        }
                                    }
                                    Item {
                                        Layout.fillWidth: true
                                        implicitHeight: 25
                                        Button {
                                            anchors.centerIn: parent
                                            visible: historyCard.hovered || root.current === historyCard.modelData.path
                                            text: "Restore"
                                            implicitWidth: 82
                                            implicitHeight: 24
                                            padding: 3
                                            background: Rectangle {
                                                radius: Theme.radius(12)
                                                color: parent.hovered ? Theme.accentHover : Theme.accent
                                            }
                                            contentItem: Text {
                                                text: parent.text
                                                color: Theme.accentText
                                                font.pixelSize: 11
                                                horizontalAlignment: Text.AlignHCenter
                                                verticalAlignment: Text.AlignVCenter
                                            }
                                            onClicked: root.restoreQuickCapture(historyCard.modelData)
                                        }
                                    }
                                }
                            }
                            Label {
                                anchors.centerIn: parent
                                visible: root.captures.length === 0
                                text: "No captures"
                                color: Theme.textMuted
                                font.pixelSize: 12
                            }
                        }
                        Label {
                            text: root.preferences.retention_days === 0 ? "Kept until deleted" : "Kept for " + (root.preferences.retention_days === undefined ? 30 : root.preferences.retention_days) + " days"
                            font.pixelSize: 11
                            color: Theme.textMuted
                        }
                    }
                }
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Flickable {
                        id: previewViewport
                        anchors.fill: parent
                        visible: !root.editing
                        clip: true
                        contentWidth: Math.max(width, preview.width + 48)
                        contentHeight: Math.max(height, preview.height + 48)
                        ScrollBar.horizontal: ScrollBar {}
                        ScrollBar.vertical: ScrollBar {}
                        Image {
                            id: preview
                            x: (previewViewport.contentWidth - width) / 2
                            y: (previewViewport.contentHeight - height) / 2
                            width: root.previewZoom ? sourceSize.width * root.previewZoom : Math.max(1, previewViewport.width - 64)
                            height: root.previewZoom ? sourceSize.height * root.previewZoom : Math.max(1, previewViewport.height - 64)
                            source: root.current ? "file://" + root.current : ""
                            fillMode: Image.PreserveAspectFit
                            cache: false
                            asynchronous: true
                            Drag.active: dragger.drag.active
                            Drag.dragType: Drag.Automatic
                            Drag.supportedActions: Qt.CopyAction
                            Drag.mimeData: ({
                                    "text/uri-list": "file://" + root.current
                                })
                            MouseArea {
                                id: dragger
                                anchors.fill: parent
                                drag.target: dragProxy
                                enabled: !!root.current
                                onPressed: preview.grabToImage(function (result) {
                                    preview.Drag.imageSource = result.url;
                                })
                            }
                            Item {
                                id: dragProxy
                            }
                        }
                    }
                    Column {
                        anchors.centerIn: parent
                        spacing: 16
                        visible: !root.current
                        Icon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            name: "capture"
                            size: 46
                            color: Theme.mix(Theme.accent, Theme.window, 0.35)
                        }
                        Text {
                            text: "Make room for a good shot."
                            color: Theme.textSoft
                            font.pixelSize: 21
                            font.weight: Font.Medium
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "Capture an area, or open an image."
                            color: Theme.textMuted
                            font.pixelSize: 13
                        }
                    }
                    Editor {
                        id: editor
                        anchors.fill: parent
                        visible: root.editing
                        sourcePath: root.editing ? root.current : ""
                        backend: root.backend
                        onCloseRequested: cancelEdits.open()
                        onHistoryRequested: {
                            root.showHistory = !root.showHistory;
                            root.refresh();
                        }
                        customPresets: root.preferences.background_presets || []
                        onPresetsChanged: function (presets) {
                            var c = Object.assign({}, root.preferences);
                            c.background_presets = presets;
                            root.preferences = c;
                            root.savePreferences(c, "presets-save");
                        }
                        onSaved: function (path) {
                            root.current = path;
                            root.editing = false;
                            root.status = "Done";
                            Qt.callLater(root.refresh);
                        }
                        onError: function (message) {
                            root.status = message;
                        }
                    }
                }
            }
            Rectangle {
                visible: !root.editing
                Layout.fillWidth: true
                implicitHeight: 55
                color: Theme.panel
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    spacing: 4
                    ComboBox {
                        model: ["Fit", "50%", "100%", "200%"]
                        implicitWidth: 83
                        implicitHeight: 30
                        onActivated: root.previewZoom = [0, 0.5, 1, 2][currentIndex]
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                    Rectangle {
                        implicitWidth: 110
                        implicitHeight: 30
                        radius: Theme.radius(15)
                        color: Theme.surface
                        border.color: Theme.border
                        visible: !!root.current
                        Row {
                            anchors.centerIn: parent
                            spacing: 8
                            Icon {
                                name: "drag"
                                size: 14
                                color: Theme.textMuted
                            }
                            Text {
                                text: "Drag Me"
                                color: Theme.textSoft
                                font.pixelSize: 11
                            }
                        }
                        Drag.active: footerDrag.drag.active
                        Drag.dragType: Drag.Automatic
                        Drag.supportedActions: Qt.CopyAction
                        Drag.mimeData: ({
                                "text/uri-list": "file://" + root.current
                            })
                        MouseArea {
                            id: footerDrag
                            anchors.fill: parent
                            drag.target: footerProxy
                        }
                        Item {
                            id: footerProxy
                        }
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                    IconButton {
                        iconName: "text"
                        text: "Annotate"
                        enabled: !!root.current
                        onClicked: root.beginEditing()
                    }
                    IconButton {
                        iconName: "pin"
                        text: "Pin screenshot"
                        enabled: !!root.current
                        onClicked: root.pin()
                    }
                    IconButton {
                        iconName: "copy"
                        text: "Copy"
                        enabled: !!root.current && !worker.running
                        onClicked: root.run(["copy", root.current])
                    }
                    IconButton {
                        iconName: "save"
                        text: "Save as…"
                        enabled: !!root.current
                        onClicked: exporter.open()
                    }
                    IconButton {
                        iconName: "more"
                        text: "More actions"
                        enabled: !!root.current
                        onClicked: imageMenu.open()
                    }
                }
            }
            Rectangle {
                visible: !["Ready", "Done"].includes(root.status)
                Layout.fillWidth: true
                implicitHeight: statusLabel.implicitHeight + 16
                color: Theme.accentSoft
                Label {
                    id: statusLabel
                    anchors.fill: parent
                    anchors.margins: 8
                    text: root.status
                    color: Theme.text
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }
            }
        }
        Menu {
            id: pinsMenu
            palette: Theme.controls.palette
            x: Math.max(10, window.width - width - 60)
            y: 55
            MenuItem {
                text: "Make pins interactive"
                onTriggered: root.unlockPins()
            }
            MenuItem {
                text: "Unpin all"
                onTriggered: root.pins = []
            }
        }
        Menu {
            id: imageMenu
            palette: Theme.controls.palette
            x: window.width - width - 14
            y: window.height - height - 55
            MenuItem {
                text: "Extract text"
                onTriggered: root.run(["ocr", root.current], "ocr")
            }
            MenuItem {
                text: "Read QR code"
                onTriggered: root.run(["qr", root.current], "qr")
            }
            MenuSeparator {}
            MenuItem {
                text: "Delete capture"
                onTriggered: deletion.open()
            }
        }
        Popup {
            id: captureOptions
            palette: Theme.controls.palette
            x: 160
            y: 55
            padding: 18
            ColumnLayout {
                spacing: 10
                RowLayout {
                    Label {
                        text: "Delay"
                    }
                    SpinBox {
                        from: 0
                        to: 60
                        value: root.delay
                        onValueModified: root.delay = value
                    }
                    Label {
                        text: "sec"
                    }
                }
                CheckBox {
                    text: "Include cursor"
                    checked: root.cursor
                    onToggled: root.cursor = checked
                }
                CheckBox {
                    text: "Scroll horizontally"
                    checked: root.horizontalScroll
                    onToggled: root.horizontalScroll = checked
                }
            }
        }
        Dialog {
            id: cancelEdits
            palette: Theme.controls.palette
            title: "Discard unsaved edits?"
            anchors.centerIn: parent
            standardButtons: Dialog.Discard | Dialog.Cancel
            onDiscarded: root.editing = false
        }
        Dialog {
            id: deletion
            palette: Theme.controls.palette
            title: "Delete this capture from history?"
            anchors.centerIn: parent
            standardButtons: Dialog.Ok | Dialog.Cancel
            onAccepted: {
                root.run(["delete", root.current], "delete");
                root.current = "";
            }
        }
        Dialog {
            id: output
            palette: Theme.controls.palette
            title: "Result"
            anchors.centerIn: parent
            width: Math.min(650, window.width - 40)
            height: Math.min(350, window.height - 40)
            standardButtons: Dialog.Close
            ScrollView {
                anchors.fill: parent
                TextArea {
                    id: outputText
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                }
            }
        }
        Dialog {
            id: settings
            palette: Theme.controls.palette
            title: "Preferences"
            anchors.centerIn: parent
            width: Math.min(650, window.width - 40)
            height: Math.min(630, window.height - 40)
            standardButtons: Dialog.Save | Dialog.Cancel
            onAccepted: {
                var c = Object.assign({}, root.preferences);
                c.delay = prefDelay.value;
                c.cursor = prefCursor.checked;
                c.retention_days = prefRetention.value;
                c.format = ["png", "jpeg", "webp"][prefFormat.currentIndex];
                c.ocr_language = prefLanguage.text;
                delete c.upload_url;
                delete c.upload_token;
                c.overlay_timeout = prefTimeout.value;
                c.overlay_position = ["bottom-right", "bottom-left", "top-right", "top-left"][prefPosition.currentIndex];
                c.show_overlay = prefShowOverlay.checked;
                c.copy_after_capture = prefAutoCopy.checked;
                c.save_after_capture = prefAutoSave.checked;
                c.annotate_after_capture = prefAutoEdit.checked;
                c.pin_after_capture = prefAutoPin.checked;
                c.export_directory = prefExportDirectory.text;
                c.overlay_size = prefOverlaySize.value;
                c.overlay_screen = prefOverlayScreen.currentText;
                c.dismiss_after_drop = prefDismissDrop.checked;
                c.freeze_capture = prefFreeze.checked;
                c.show_crosshair = prefCrosshair.checked;
                c.show_magnifier = prefMagnifier.checked;
                c.window_transparent = prefWindowTransparent.checked;
                c.corners = ["auto", "square", "rounded"][prefCorners.currentIndex];
                root.preferences = c;
                root.delay = c.delay;
                root.cursor = c.cursor;
                root.savePreferences(c, "settings-save");
                root.saveShortcuts();
            }
            ScrollView {
                anchors.fill: parent
                contentWidth: availableWidth
                ColumnLayout {
                    width: settings.availableWidth
                    spacing: 12
                    Label {
                        text: "Expired captures are cleaned automatically; exported files are kept."
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                        font.pixelSize: 12
                        opacity: 0.65
                    }
                    Label {
                        text: "Appearance"
                        font.bold: true
                        font.pixelSize: 17
                    }
                    RowLayout {
                        Label {
                            text: "Corners"
                            Layout.fillWidth: true
                        }
                        ComboBox {
                            id: prefCorners
                            model: ["Follow Hyprland", "Square", "Rounded"]
                            Layout.preferredWidth: 180
                        }
                    }
                    Label {
                        text: "Capture"
                        font.bold: true
                        font.pixelSize: 17
                    }
                    RowLayout {
                        Label {
                            text: "Delay (seconds)"
                            Layout.fillWidth: true
                        }
                        SpinBox {
                            id: prefDelay
                            from: 0
                            to: 60
                        }
                        CheckBox {
                            id: prefCursor
                            text: "Include cursor"
                        }
                    }
                    RowLayout {
                        Label {
                            text: "File format"
                            Layout.fillWidth: true
                        }
                        ComboBox {
                            id: prefFormat
                            model: ["PNG", "JPEG", "WebP"]
                        }
                    }
                    RowLayout {
                        Label {
                            text: "Keep captures for days (0 = forever)"
                            Layout.fillWidth: true
                        }
                        SpinBox {
                            id: prefRetention
                            from: 0
                            to: 3650
                        }
                    }
                    RowLayout {
                        Label {
                            text: "OCR language"
                            Layout.fillWidth: true
                        }
                        TextField {
                            id: prefLanguage
                            placeholderText: "eng"
                            Layout.preferredWidth: 180
                        }
                    }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 8
                        CheckBox {
                            id: prefFreeze
                            text: "Freeze screen during selection"
                        }
                        CheckBox {
                            id: prefCrosshair
                            text: "Full crosshair guides"
                        }
                        CheckBox {
                            id: prefMagnifier
                            text: "Pixel magnifier"
                        }
                        CheckBox {
                            id: prefWindowTransparent
                            text: "Isolate window from desktop (PNG/WebP)"
                        }
                    }
                    Label {
                        text: "After capture"
                        font.bold: true
                        font.pixelSize: 17
                    }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 8
                        CheckBox {
                            id: prefShowOverlay
                            text: "Show quick access"
                        }
                        CheckBox {
                            id: prefAutoCopy
                            text: "Copy"
                        }
                        CheckBox {
                            id: prefAutoSave
                            text: "Export automatically"
                        }
                        CheckBox {
                            id: prefAutoEdit
                            text: "Annotate"
                        }
                        CheckBox {
                            id: prefAutoPin
                            text: "Pin"
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        TextField {
                            id: prefExportDirectory
                            Layout.fillWidth: true
                            placeholderText: "Export directory"
                            readOnly: true
                        }
                        IconButton {
                            iconName: "folder"
                            text: "Choose export directory"
                            onClicked: exportFolder.open()
                        }
                    }
                    Label {
                        visible: prefAutoSave.checked && !prefExportDirectory.text
                        Layout.fillWidth: true
                        text: "Choose a directory to enable automatic export."
                        font.pixelSize: 11
                        wrapMode: Text.Wrap
                    }
                    Label {
                        text: "Quick access"
                        font.bold: true
                        font.pixelSize: 17
                    }
                    RowLayout {
                        Label {
                            text: "Position"
                            Layout.fillWidth: true
                        }
                        ComboBox {
                            id: prefPosition
                            model: ["Bottom right", "Bottom left", "Top right", "Top left"]
                        }
                    }
                    RowLayout {
                        Label {
                            text: "Dismiss after seconds (0 stays open)"
                            Layout.fillWidth: true
                        }
                        SpinBox {
                            id: prefTimeout
                            from: 0
                            to: 300
                        }
                    }
                    RowLayout {
                        Label {
                            text: "Thumbnail size"
                            Layout.fillWidth: true
                        }
                        SpinBox {
                            id: prefOverlaySize
                            from: 100
                            to: 480
                            stepSize: 10
                            editable: true
                        }
                    }
                    RowLayout {
                        Label {
                            text: "Display"
                            Layout.fillWidth: true
                        }
                        ComboBox {
                            id: prefOverlayScreen
                            model: ["active"].concat(Quickshell.screens.map(function (s) {
                                return s.name;
                            }))
                            Layout.preferredWidth: 180
                        }
                    }
                    CheckBox {
                        id: prefDismissDrop
                        text: "Dismiss preview after dropping into another app"
                    }
                    Label {
                        text: "Keyboard shortcuts"
                        font.bold: true
                        font.pixelSize: 17
                    }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        font.pixelSize: 12
                        opacity: 0.65
                        text: root.shortcutInfo.available === false ? root.shortcutInfo.reason : "Focus a field and press the combination, or type it, e.g. SUPER + ALT + S. Combinations Hyprland already uses can only be typed; saving replaces them."
                    }
                    Repeater {
                        model: root.shortcutInfo.actions || []
                        delegate: ColumnLayout {
                            id: shortcutRow
                            required property var modelData
                            readonly property string note: root.shortcutNote(shortcutRow.modelData.id, shortcutField.text)
                            Layout.fillWidth: true
                            spacing: 2
                            RowLayout {
                                Layout.fillWidth: true
                                Label {
                                    text: {
                                        let name = shortcutRow.modelData.label.replace(/^OmaShot /, "");
                                        return name.charAt(0).toUpperCase() + name.slice(1);
                                    }
                                    Layout.fillWidth: true
                                }
                                TextField {
                                    id: shortcutField
                                    objectName: "shortcut-" + shortcutRow.modelData.id
                                    Layout.preferredWidth: 220
                                    enabled: root.shortcutInfo.available === true
                                    text: root.shortcutDraft[shortcutRow.modelData.id] || ""
                                    placeholderText: "Not set"
                                    Accessible.name: shortcutRow.modelData.label + " shortcut"
                                    function store(value) {
                                        let draft = Object.assign({}, root.shortcutDraft);
                                        draft[shortcutRow.modelData.id] = value;
                                        root.shortcutDraft = draft;
                                    }
                                    onTextEdited: store(text)
                                    Keys.onPressed: function (event) {
                                        let keys = root.eventChord(event);
                                        if (!keys)
                                            return;
                                        text = keys;
                                        store(keys);
                                        event.accepted = true;
                                    }
                                }
                                IconButton {
                                    iconName: "close"
                                    text: "Clear shortcut"
                                    size: 30
                                    iconSize: 16
                                    enabled: shortcutField.enabled && shortcutField.text.length > 0
                                    onClicked: {
                                        shortcutField.text = "";
                                        shortcutField.store("");
                                    }
                                }
                            }
                            Label {
                                visible: shortcutRow.note.length > 0
                                text: shortcutRow.note
                                color: shortcutRow.note.startsWith("Replaces") ? Theme.warning : Theme.danger
                                font.pixelSize: 11
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                            }
                        }
                    }
                    Label {
                        text: "Omarchy has no desktop icons by default. Optional icon-provider hide/restore commands are documented in the README."
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                        opacity: 0.7
                    }
                }
            }
        }
    }
    Timer {
        id: scrollTimer
        interval: 350
        onTriggered: {
            if (worker.running) {
                restart();
                return;
            }
            root.opened = false;
            root.quickOpened = false;
            root.capturing = true;
            root.run(["scroll", "start"].concat(root.scrollGeometryHint ? ["--geometry", root.scrollGeometryHint] : []).concat(root.horizontalScroll ? ["--horizontal"] : []), "scroll-start");
        }
    }
    CaptureSelector {
        id: selector
        showCrosshair: root.preferences.show_crosshair !== false
        showMagnifier: root.preferences.show_magnifier !== false
        onSelected: function (geometry) {
            root.finishFrozenSelection(geometry);
        }
        onCancelled: root.cancelFrozenSelection()
    }
    QuickAccess {
        id: quickAccess
        captures: root.quickCaptures
        opened: root.quickOpened
        suspended: root.capturing || scrollSurface.active
        corner: root.preferences.overlay_position || "bottom-right"
        outputName: root.preferences.overlay_screen || "active"
        thumbnailWidth: Number(root.preferences.overlay_size || 240)
        timeoutSeconds: Number(root.preferences.overlay_timeout || 0)
        dismissAfterDrop: root.preferences.dismiss_after_drop !== false
        onDismissRequested: function (id) {
            root.dismissQuick(id);
        }
        onCopyRequested: function (path) {
            root.queueCaptureAction(["copy", path], "post-quick-copy");
        }
        onSaveRequested: function (path) {
            root.exportSource = path;
            root.quickOpened = false;
            root.opened = true;
            exporter.open();
        }
        onAnnotateRequested: function (path) {
            root.current = path;
            root.beginEditing();
        }
        onPinRequested: function (path) {
            root.pin(path);
        }
        onHistoryRequested: {
            root.showHistory = true;
            root.open("{}");
        }
    }
    ScrollCapture {
        id: scrollSurface
        backend: root.backend
        onFinished: function (result) {
            root.scrollSession = "";
            root.capturing = false;
            root.status = "Done";
            root.receiveCapture(result);
        }
        onCancelled: {
            root.scrollSession = "";
            root.capturing = false;
            root.status = "Done";
            root.quickOpened = !!root.quickCaptures.length;
        }
        onFailed: function (message) {
            root.status = message;
        }
    }
    Variants {
        id: pinSurfaces
        model: root.pins
        PanelWindow {
            id: pinWindow
            required property var modelData
            readonly property int index: root.pins.findIndex(function (p) {
                return p.id === modelData.id;
            })
            visible: loaded && !root.capturing && !scrollSurface.active
            property bool loaded: false
            property bool clickThrough: false
            property real imageOpacity: 1
            property real offsetX: 0
            property real offsetY: 0
            readonly property real aspect: photo.implicitWidth > 0 ? photo.implicitHeight / photo.implicitWidth : 0.75
            mask: clickThrough ? emptyRegion : null
            Region {
                id: emptyRegion
            }
            implicitWidth: 360
            implicitHeight: Math.max(60, implicitWidth * aspect)
            anchors {
                top: true
                right: true
            }
            margins {
                top: 70 + pinWindow.index * 30 + offsetY
                right: 24 + pinWindow.index * 30 - offsetX
            }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "omashot-pin"
            color: "transparent"
            Item {
                anchors.fill: parent
                palette: Theme.controls.palette
                HoverHandler {
                    id: pinHover
                }
                Image {
                    id: photo
                    anchors.fill: parent
                    source: "file://" + pinWindow.modelData.path
                    fillMode: Image.PreserveAspectFit
                    visible: false
                    // Decode off the GUI thread at the pin's pixel size (stepped, never upscaled); keep the old frame while zooming reloads it.
                    asynchronous: true
                    retainWhileLoading: true
                    sourceSize.width: Math.ceil(pinWindow.implicitWidth * (pinWindow.screen ? pinWindow.screen.devicePixelRatio : 1) / 256) * 256
                    onStatusChanged: if (status === Image.Ready)
                        pinWindow.loaded = true
                }
                Rectangle {
                    id: roundedMask
                    anchors.fill: parent
                    radius: Theme.radius(9)
                    color: "white"
                    layer.enabled: true
                    visible: false
                }
                MultiEffect {
                    anchors.fill: parent
                    source: photo
                    maskEnabled: true
                    maskSource: roundedMask
                    opacity: pinWindow.imageOpacity
                }
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radius(9)
                    color: "transparent"
                    border.width: 1
                    border.color: pinHover.hovered ? Theme.accent : Theme.alpha(Theme.borderStrong, 0.6)
                }
                MouseArea {
                    anchors.fill: parent
                    property point start
                    property real ox
                    property real oy
                    onPressed: function (e) {
                        start = mapToGlobal(e.x, e.y);
                        ox = pinWindow.offsetX;
                        oy = pinWindow.offsetY;
                    }
                    onPositionChanged: function (e) {
                        if (pressed) {
                            let p = mapToGlobal(e.x, e.y);
                            pinWindow.offsetX = ox + p.x - start.x;
                            pinWindow.offsetY = oy + p.y - start.y;
                        }
                    }
                    onWheel: function (w) {
                        pinWindow.implicitWidth = Math.max(100, Math.min((pinWindow.screen ? pinWindow.screen.width : 2000) - 20, pinWindow.implicitWidth * (w.angleDelta.y > 0 ? 1.08 : 0.92)));
                        w.accepted = true;
                    }
                }
                Rectangle {
                    anchors.top: parent.top
                    anchors.topMargin: 5
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: pinHover.hovered
                    width: 48
                    height: 20
                    radius: Theme.radius(10)
                    color: Theme.alpha(Theme.window, 0.85)
                    Text {
                        anchors.centerIn: parent
                        text: Math.round(pinWindow.implicitWidth / Math.max(1, pinWindow.modelData.width || photo.implicitWidth) * 100) + "%"
                        font.pixelSize: 10
                        color: Theme.text
                    }
                }
                IconButton {
                    anchors {
                        left: parent.left
                        top: parent.top
                        margins: 5
                    }
                    visible: pinHover.hovered
                    size: 23
                    iconSize: 13
                    iconName: "close"
                    text: "Unpin screenshot"
                    background: Rectangle {
                        radius: Theme.radius(12)
                        color: Theme.alpha(Theme.window, 0.9)
                    }
                    contentItem: Icon {
                        name: "close"
                        size: 13
                        color: Theme.text
                    }
                    onClicked: {
                        let p = root.pins.slice();
                        p.splice(pinWindow.index, 1);
                        root.pins = p;
                    }
                }
                IconButton {
                    anchors {
                        right: parent.right
                        top: parent.top
                        margins: 5
                    }
                    visible: pinHover.hovered
                    size: 23
                    iconSize: 13
                    iconName: "pin"
                    text: "Pass clicks through; restore interaction from pinned screenshot controls"
                    background: Rectangle {
                        radius: Theme.radius(12)
                        color: Theme.alpha(Theme.window, 0.9)
                    }
                    contentItem: Icon {
                        name: "pin"
                        size: 13
                        color: Theme.text
                    }
                    onClicked: pinWindow.clickThrough = true
                }
                Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 6
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: pinHover.hovered
                    width: Math.min(120, parent.width - 64)
                    height: 22
                    radius: Theme.radius(11)
                    color: Theme.alpha(Theme.window, 0.8)
                    Slider {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        from: 0.2
                        to: 1
                        value: pinWindow.imageOpacity
                        onValueChanged: pinWindow.imageOpacity = value
                        Accessible.name: "Pinned screenshot opacity"
                        ToolTip.visible: hovered
                        ToolTip.text: "Opacity " + Math.round(value * 100) + "%"
                        ToolTip.delay: 400
                    }
                }
                IconButton {
                    anchors {
                        left: parent.left
                        bottom: parent.bottom
                        margins: 5
                    }
                    visible: pinHover.hovered
                    size: 23
                    iconSize: 13
                    iconName: "more"
                    text: "Move to display / resize"
                    background: Rectangle {
                        radius: Theme.radius(12)
                        color: Theme.alpha(Theme.window, 0.9)
                    }
                    contentItem: Icon {
                        name: "more"
                        size: 13
                        color: Theme.text
                    }
                    onClicked: pinMenu.open()
                }
                IconButton {
                    id: resizeGrip
                    anchors {
                        right: parent.right
                        bottom: parent.bottom
                        margins: 5
                    }
                    visible: pinHover.hovered
                    size: 23
                    iconSize: 13
                    iconName: "resize"
                    text: "Drag to resize"
                    background: Rectangle {
                        radius: Theme.radius(12)
                        color: Theme.alpha(Theme.window, 0.9)
                    }
                    contentItem: Icon {
                        name: "resize"
                        size: 13
                        color: Theme.text
                    }
                    MouseArea {
                        anchors.fill: parent
                        property point start
                        property real initialWidth
                        cursorShape: Qt.SizeFDiagCursor
                        onPressed: function (e) {
                            start = mapToGlobal(e.x, e.y);
                            initialWidth = pinWindow.implicitWidth;
                        }
                        onPositionChanged: function (e) {
                            if (pressed) {
                                let p = mapToGlobal(e.x, e.y);
                                pinWindow.implicitWidth = Math.max(100, Math.min((pinWindow.screen ? pinWindow.screen.width : 2000) - 20, initialWidth + p.x - start.x));
                            }
                        }
                    }
                }
                Menu {
                    id: pinMenu
                    palette: Theme.controls.palette
                    x: 8
                    y: 28
                    MenuItem {
                        text: "Smaller"
                        onTriggered: pinWindow.implicitWidth = Math.max(100, pinWindow.implicitWidth * 0.8)
                    }
                    MenuItem {
                        text: "Larger"
                        onTriggered: pinWindow.implicitWidth = Math.min((pinWindow.screen ? pinWindow.screen.width : 2000) - 20, pinWindow.implicitWidth * 1.25)
                    }
                    MenuSeparator {}
                    Instantiator {
                        model: Quickshell.screens
                        delegate: MenuItem {
                            required property var modelData
                            text: "Move to " + modelData.name
                            onTriggered: pinWindow.screen = modelData
                        }
                        onObjectAdded: function (index, object) {
                            pinMenu.insertItem(index + 3, object);
                        }
                        onObjectRemoved: function (index, object) {
                            pinMenu.removeItem(object);
                        }
                    }
                }
            }
        }
    }
}
