import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Item {
    id: root
    property string backend: "omashot"
    property bool active: false
    property bool polling: false
    property string session: ""
    property string geometry: ""
    property var region: ({
            x: 0,
            y: 0,
            w: 1,
            h: 1
        })
    property var output: Quickshell.screens[0]
    property string previewPath: ""
    property int previewRevision: 0
    readonly property bool previewReady: previewImage.status === Image.Ready
    property int capturedWidth: 0
    property int capturedHeight: 0
    property string message: ""
    property string pending: ""
    property bool takingFrame: false
    readonly property real localX: region.x - (output ? output.x : 0)
    readonly property real localY: region.y - (output ? output.y : 0)
    readonly property bool controlsBelow: localY + region.h + 58 < (output ? output.height : 1000)
    readonly property bool controlsAbove: localY > 58
    readonly property bool controlsOverlap: !controlsBelow && !controlsAbove
    readonly property bool previewOnLeft: localX > 130
    readonly property bool previewOnRight: (output ? output.width : 1000) - localX - region.w > 130
    readonly property bool previewOverlap: !previewOnLeft && !previewOnRight
    signal finished(var result)
    signal cancelled
    signal failed(string message)
    function start(id, selectedGeometry) {
        let match = /^(-?\d+),(-?\d+)\s+(\d+)x(\d+)$/.exec(selectedGeometry);
        if (!match) {
            failed("Invalid selected region");
            return;
        }
        session = id;
        geometry = selectedGeometry;
        region = {
            x: Number(match[1]),
            y: Number(match[2]),
            w: Number(match[3]),
            h: Number(match[4])
        };
        output = Quickshell.screens.find(function (s) {
            let x = region.x + region.w / 2, y = region.y + region.h / 2;
            return x >= s.x && x < s.x + s.width && y >= s.y && y < s.y + s.height;
        }) || Quickshell.screens[0];
        active = true;
        polling = false;
        previewPath = "";
        previewRevision = 0;
        pending = "";
        message = "";
        capturedWidth = 0;
        capturedHeight = 0;
    }
    function begin() {
        if (active) {
            polling = true;
            message = "Scroll the selected app";
            sampleTimer.restart();
        }
    }
    function requestFinish() {
        if (!active)
            return;
        polling = false;
        pending = "finish";
        drain();
    }
    function requestCancel() {
        if (!active)
            return;
        polling = false;
        pending = "cancel";
        drain();
    }
    function drain() {
        if (!active || worker.running || prepareSample.running)
            return;
        if (pending) {
            let operation = pending;
            pending = "";
            worker.operation = operation;
            worker.command = [backend, "scroll", operation, session];
            worker.running = true;
        }
    }
    Timer {
        id: sampleTimer
        interval: 750
        repeat: true
        running: root.active && root.polling
        onTriggered: {
            if (!worker.running && !prepareSample.running) {
                root.takingFrame = true;
                prepareSample.start();
            }
        }
    }
    Timer {
        id: prepareSample
        interval: 90
        onTriggered: {
            if (root.pending) {
                root.takingFrame = false;
                root.drain();
                return;
            }
            worker.operation = "append";
            worker.command = [root.backend, "scroll", "append", root.session];
            worker.running = true;
        }
    }
    Process {
        id: worker
        property string operation: ""
        property string result: ""
        onStarted: result = ""
        stdout: StdioCollector {
            onStreamFinished: worker.result = text
        }
        onExited: function (code) {
            root.takingFrame = false;
            let value;
            try {
                value = JSON.parse(result);
            } catch (e) {
                value = {
                    error: "Capture action failed"
                };
            }
            if (code !== 0 || value.error) {
                root.message = value.error || "Capture action failed";
                if (operation !== "append")
                    root.failed(root.message);
            } else if (operation === "append") {
                root.previewPath = value.path;
                root.previewRevision++;
                root.capturedWidth = value.width;
                root.capturedHeight = value.height;
                root.message = "Scroll the selected app";
            } else if (operation === "finish") {
                root.active = false;
                root.polling = false;
                root.session = "";
                root.finished(value);
            } else if (operation === "cancel") {
                root.active = false;
                root.polling = false;
                root.session = "";
                root.cancelled();
            }
            if (root.pending)
                Qt.callLater(root.drain);
        }
    }
    // This input-transparent scrim leaves the sampled viewport untouched.
    PanelWindow {
        screen: root.output
        visible: root.active
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "omashot-scrolling-region"
        mask: Region {}
        color: "transparent"
        Rectangle {
            x: 0
            y: 0
            width: parent.width
            height: Math.max(0, root.localY)
            color: Theme.alpha(Theme.background, 0.4)
        }
        Rectangle {
            x: 0
            y: root.localY + root.region.h
            width: parent.width
            height: Math.max(0, parent.height - y)
            color: Theme.alpha(Theme.background, 0.4)
        }
        Rectangle {
            x: 0
            y: root.localY
            width: Math.max(0, root.localX)
            height: root.region.h
            color: Theme.alpha(Theme.background, 0.4)
        }
        Rectangle {
            x: root.localX + root.region.w
            y: root.localY
            width: Math.max(0, parent.width - x)
            height: root.region.h
            color: Theme.alpha(Theme.background, 0.4)
        }
        Rectangle {
            x: root.localX - 2
            y: root.localY - 2
            width: root.region.w + 4
            height: root.region.h + 4
            color: "transparent"
            border.color: Theme.accent
            border.width: 1
        }
    }
    PanelWindow {
        id: controls
        screen: root.output
        visible: root.active && !(root.takingFrame && root.controlsOverlap)
        anchors {
            top: true
            left: true
        }
        margins {
            top: root.controlsBelow ? root.localY + root.region.h + 10 : root.controlsAbove ? root.localY - 48 : Math.max(10, Math.min(root.localY + root.region.h - 48, (screen ? screen.height : 1000) - 50))
            left: Math.max(10, Math.min(root.localX + root.region.w / 2 - implicitWidth / 2, (screen ? screen.width : 1000) - implicitWidth - 10))
        }
        implicitWidth: root.polling ? 300 : 270
        implicitHeight: 40
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "omashot-scrolling-controls"
        color: "transparent"
        Rectangle {
            anchors.fill: parent
            radius: 20
            color: Theme.alpha(Theme.panel, 0.96)
            border.color: Theme.border
            palette: Theme.controls.palette
            RowLayout {
                anchors.fill: parent
                anchors.margins: 5
                spacing: 5
                Button {
                    text: root.polling ? "Pause" : "Start Capture"
                    implicitHeight: 30
                    onClicked: {
                        if (root.polling)
                            root.polling = false;
                        else
                            root.begin();
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
                Button {
                    text: "Cancel"
                    implicitHeight: 30
                    onClicked: root.requestCancel()
                }
                Button {
                    text: "Done"
                    implicitHeight: 30
                    onClicked: root.requestFinish()
                }
            }
        }
    }
    PanelWindow {
        id: preview
        screen: root.output
        visible: root.active && !!root.previewPath && !(root.takingFrame && root.previewOverlap)
        anchors {
            top: true
            left: true
        }
        margins {
            left: root.previewOnLeft ? Math.max(10, root.localX - 120) : root.previewOnRight ? root.localX + root.region.w + 16 : Math.max(10, (screen ? screen.width : 1000) - 120)
            top: Math.max(10, Math.min(root.localY, (screen ? screen.height : 1000) - implicitHeight - 10))
        }
        implicitWidth: 104
        implicitHeight: Math.min(500, Math.max(70, 96 * root.capturedHeight / Math.max(1, root.capturedWidth))) + 26
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "omashot-scrolling-preview"
        mask: Region {}
        color: "transparent"
        Rectangle {
            anchors.fill: parent
            radius: 6
            color: Theme.alpha(Theme.panel, 0.9)
            border.color: Theme.borderStrong
            Image {
                id: previewImage
                anchors.fill: parent
                anchors.margins: 4
                anchors.bottomMargin: 22
                source: root.previewPath ? "file://" + root.previewPath + "#frame-" + root.previewRevision : ""
                cache: false
                fillMode: Image.PreserveAspectFit
                sourceSize.width: 200
            }
            Text {
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 5
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.capturedWidth + " × " + root.capturedHeight
                color: Theme.textSoft
                font.pixelSize: 9
            }
        }
    }
    PanelWindow {
        screen: root.output
        visible: root.active && !!root.message && root.message !== "Scroll the selected app" && !(root.takingFrame && root.controlsOverlap)
        anchors {
            top: true
            left: true
        }
        margins {
            left: controls.margins.left
            top: Math.max(8, controls.margins.top - 28)
        }
        implicitWidth: Math.min(560, (screen ? screen.width : 1000) - 40)
        implicitHeight: 24
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        color: "transparent"
        Text {
            anchors.fill: parent
            text: root.message
            color: Theme.warning
            font.pixelSize: 11
            elide: Text.ElideRight
        }
    }
}
