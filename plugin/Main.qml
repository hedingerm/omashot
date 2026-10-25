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
        opened = false;
        quickOpened = false;
        capturing = true;
        pendingMode = mode;
        captureTimer.start();
    }
    function beginScrolling(geometry) {
        if (scrollSurface.active)
            return;
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
            pins = pins.concat([
                {
                    path: target,
                    id: pinCounter
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
                root.status = data.error || err;
                root.opened = true;
                return;
            }
            root.status = "Done";
            if (root.captureActionQueue.length)
                captureActionTimer.restart();
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
                prefOverlaySize.value = data.overlay_size || 160;
                prefOverlayScreen.currentIndex = Math.max(0, prefOverlayScreen.model.indexOf(data.overlay_screen || "active"));
                prefDismissDrop.checked = data.dismiss_after_drop !== false;
                prefFreeze.checked = data.freeze_capture !== false;
                prefCrosshair.checked = data.show_crosshair !== false;
                prefMagnifier.checked = data.show_magnifier !== false;
                prefWindowTransparent.checked = !!data.window_transparent;
                settings.open();
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
        color: "#15171f"
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
            anchors.fill: parent
            spacing: 0
            Rectangle {
                visible: !root.editing
                Layout.fillWidth: true
                implicitHeight: 58
                color: "#20222d"
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
                            color: "#f1effa"
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
                            color: "#3e4052"
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
                color: "#323542"
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0
                Rectangle {
                    visible: root.showHistory
                    Layout.preferredWidth: Math.min(226, window.width * 0.35)
                    Layout.fillHeight: true
                    color: "#1c1e29"
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 12
                        RowLayout {
                            Label {
                                text: "History"
                                font.pixelSize: 15
                                font.weight: Font.DemiBold
                                color: "#e8e6f3"
                                Layout.fillWidth: true
                            }
                            Label {
                                text: String(root.captures.length)
                                font.pixelSize: 12
                                color: "#8d91a8"
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
                                    radius: 9
                                    color: root.current === modelData.path ? "#34304c" : "#252835"
                                    border.color: root.current === modelData.path ? "#9d8bf3" : "#343747"
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
                                        cache: false
                                    }
                                    RowLayout {
                                        Label {
                                            text: root.dateLabel(modelData.modified)
                                            font.pixelSize: 11
                                            color: "#c7c5d7"
                                            Layout.fillWidth: true
                                        }
                                        Label {
                                            text: modelData.width + "×" + modelData.height
                                            font.pixelSize: 10
                                            color: "#858aa1"
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
                                                radius: 12
                                                color: parent.hovered ? "#8f79f0" : "#7258d8"
                                            }
                                            contentItem: Text {
                                                text: parent.text
                                                color: "white"
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
                                color: "#878ba0"
                                font.pixelSize: 12
                            }
                        }
                        Label {
                            text: root.preferences.retention_days === 0 ? "Kept until deleted" : "Kept for " + (root.preferences.retention_days === undefined ? 30 : root.preferences.retention_days) + " days"
                            font.pixelSize: 11
                            color: "#858aa1"
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
                            color: "#71688f"
                        }
                        Text {
                            text: "Make room for a good shot."
                            color: "#d6d3e5"
                            font.pixelSize: 21
                            font.weight: Font.Medium
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "Capture an area, or open an image."
                            color: "#81859d"
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
                color: "#20222d"
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
                        radius: 15
                        color: "#292c3a"
                        border.color: "#414555"
                        visible: !!root.current
                        Row {
                            anchors.centerIn: parent
                            spacing: 8
                            Icon {
                                name: "drag"
                                size: 14
                                color: "#8e92a9"
                            }
                            Text {
                                text: "Drag Me"
                                color: "#bcbcd0"
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
                color: "#292335"
                Label {
                    id: statusLabel
                    anchors.fill: parent
                    anchors.margins: 8
                    text: root.status
                    color: "#d0c2ee"
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }
            }
        }
        Menu {
            id: pinsMenu
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
            title: "Discard unsaved edits?"
            anchors.centerIn: parent
            standardButtons: Dialog.Discard | Dialog.Cancel
            onDiscarded: root.editing = false
        }
        Dialog {
            id: deletion
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
                root.preferences = c;
                root.delay = c.delay;
                root.cursor = c.cursor;
                root.savePreferences(c, "settings-save");
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
                            to: 320
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
                        text: "Omarchy has no desktop icons by default. Optional icon-provider hide/restore commands and keyboard shortcuts are documented in the README."
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
        thumbnailWidth: Number(root.preferences.overlay_size || 160)
        timeoutSeconds: Number(root.preferences.overlay_timeout || 0)
        dismissAfterDrop: root.preferences.dismiss_after_drop !== false
        onDismissRequested: function (id) {
            root.dismissQuick(id);
        }
        onCopyRequested: function (path) {
            root.queueCaptureAction(["copy", path], "post-copy");
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
            visible: !root.capturing && !scrollSurface.active
            property bool clickThrough: false
            property real imageOpacity: 1
            property real offsetX: 0
            property real offsetY: 0
            readonly property real aspect: photo.sourceSize.width > 0 ? photo.sourceSize.height / photo.sourceSize.width : 0.75
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
                HoverHandler {
                    id: pinHover
                }
                Image {
                    id: photo
                    anchors.fill: parent
                    source: "file://" + pinWindow.modelData.path
                    fillMode: Image.PreserveAspectFit
                    visible: false
                }
                Rectangle {
                    id: roundedMask
                    anchors.fill: parent
                    radius: 9
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
                    radius: 9
                    color: "transparent"
                    border.width: 1
                    border.color: pinHover.hovered ? "#c8c4d7" : "#507d7b88"
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
                    radius: 10
                    color: "#c022222b"
                    Text {
                        anchors.centerIn: parent
                        text: Math.round(pinWindow.implicitWidth / Math.max(1, photo.sourceSize.width) * 100) + "%"
                        font.pixelSize: 10
                        color: "white"
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
                        radius: 12
                        color: "#e7eeeeF4"
                    }
                    contentItem: Icon {
                        name: "close"
                        size: 13
                        color: "#30303a"
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
                        radius: 12
                        color: "#e7eeeeF4"
                    }
                    contentItem: Icon {
                        name: "pin"
                        size: 13
                        color: "#30303a"
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
                    radius: 11
                    color: "#cc252530"
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
                        radius: 12
                        color: "#e7eeeeF4"
                    }
                    contentItem: Icon {
                        name: "more"
                        size: 13
                        color: "#30303a"
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
                        radius: 12
                        color: "#e7eeeeF4"
                    }
                    contentItem: Icon {
                        name: "resize"
                        size: 13
                        color: "#30303a"
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
