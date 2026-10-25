import QtQuick
import Quickshell
import Quickshell.Wayland

Item {
    id: root
    property var snapshot: ({})
    property bool opened: false
    property bool showCrosshair: true
    property bool showMagnifier: true
    property real pointerX: 0
    property real pointerY: 0
    property real selectionX: 0
    property real selectionY: 0
    property real selectionWidth: 0
    property real selectionHeight: 0
    property string interaction: ""
    property real pressX: 0
    property real pressY: 0
    property bool completing: false
    readonly property real originX: Number(snapshot.originX || 0)
    readonly property real originY: Number(snapshot.originY || 0)
    readonly property real imageScale: Math.max(0.01, Number(snapshot.scale || 1))
    readonly property real logicalWidth: Number(snapshot.logicalWidth || Number(snapshot.width || 0) / imageScale)
    readonly property real logicalHeight: Number(snapshot.logicalHeight || Number(snapshot.height || 0) / imageScale)
    readonly property bool hasSelection: selectionWidth >= 1 && selectionHeight >= 1
    readonly property int pixelWidth: Math.max(1, Math.ceil((selectionX + selectionWidth - originX) * imageScale) - Math.floor((selectionX - originX) * imageScale))
    readonly property int pixelHeight: Math.max(1, Math.ceil((selectionY + selectionHeight - originY) * imageScale) - Math.floor((selectionY - originY) * imageScale))
    readonly property string geometry: Math.round(selectionX) + "," + Math.round(selectionY) + " " + Math.round(selectionWidth) + "x" + Math.round(selectionHeight)
    signal selected(string geometry)
    signal cancelled

    function clamp(value, low, high) {
        return Math.max(low, Math.min(value, high));
    }
    function monitorFor(name) {
        var list = snapshot.monitors || [];
        for (var i = 0; i < list.length; i++)
            if (list[i].name === name)
                return list[i];
        return null;
    }
    function monitorWidth(m) {
        return Number(m.logicalWidth || Number(m.width) / Number(m.scale || 1));
    }
    function monitorHeight(m) {
        return Number(m.logicalHeight || Number(m.height) / Number(m.scale || 1));
    }
    function ownerName() {
        var list = snapshot.monitors || [], x = selectionX + selectionWidth / 2, y = selectionY + selectionHeight / 2;
        for (var i = 0; i < list.length; i++)
            if (x >= list[i].x && y >= list[i].y && x < list[i].x + monitorWidth(list[i]) && y < list[i].y + monitorHeight(list[i]))
                return list[i].name;
        for (var j = 0; j < list.length; j++)
            if (pointerX >= list[j].x && pointerY >= list[j].y && pointerX < list[j].x + monitorWidth(list[j]) && pointerY < list[j].y + monitorHeight(list[j]))
                return list[j].name;
        return list.length ? list[0].name : "";
    }
    function reset() {
        selectionWidth = 0;
        selectionHeight = 0;
        interaction = "";
        completing = false;
        var first = (snapshot.monitors || [])[0];
        pointerX = Number(snapshot.cursorX === undefined ? first ? Number(first.x) + monitorWidth(first) / 2 : originX + logicalWidth / 2 : snapshot.cursorX);
        pointerY = Number(snapshot.cursorY === undefined ? first ? Number(first.y) + monitorHeight(first) / 2 : originY + logicalHeight / 2 : snapshot.cursorY);
    }
    onOpenedChanged: {
        if (opened)
            reset();
    }
    onSnapshotChanged: {
        if (opened)
            reset();
    }
    function begin(x, y) {
        if (!opened || completing)
            return;
        pointerX = x;
        pointerY = y;
        pressX = Math.round(clamp(x, originX, originX + logicalWidth));
        pressY = Math.round(clamp(y, originY, originY + logicalHeight));
        interaction = "draw";
        selectionX = pressX;
        selectionY = pressY;
        selectionWidth = 0;
        selectionHeight = 0;
    }
    function update(x, y) {
        pointerX = x;
        pointerY = y;
        if (completing || interaction !== "draw")
            return;
        var gx = Math.round(clamp(x, originX, originX + logicalWidth)), gy = Math.round(clamp(y, originY, originY + logicalHeight));
        selectionX = Math.min(pressX, gx);
        selectionY = Math.min(pressY, gy);
        selectionWidth = Math.abs(gx - pressX);
        selectionHeight = Math.abs(gy - pressY);
    }
    // Releasing the drag captures immediately; a click without a drag starts over.
    function end() {
        if (interaction !== "draw")
            return;
        interaction = "";
        if (hasSelection)
            finish();
    }
    function abort() {
        interaction = "";
        selectionWidth = 0;
        selectionHeight = 0;
    }
    function finish() {
        if (!opened || completing || !hasSelection)
            return;
        completing = true;
        selected(geometry);
    }
    function reject() {
        if (!opened || completing)
            return;
        completing = true;
        cancelled();
    }
    function key(event) {
        if (event.key === Qt.Key_Escape) {
            reject();
            event.accepted = true;
        }
    }

    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: surface
            required property var modelData
            readonly property var monitor: root.monitorFor(modelData.name)
            readonly property real monitorX: monitor ? Number(monitor.x) : 0
            readonly property real monitorY: monitor ? Number(monitor.y) : 0
            readonly property real localPointerX: root.pointerX - monitorX
            readonly property real localPointerY: root.pointerY - monitorY
            readonly property bool pointerHere: localPointerX >= 0 && localPointerY >= 0 && localPointerX < width && localPointerY < height
            readonly property real leftEdge: root.selectionX - monitorX
            readonly property real topEdge: root.selectionY - monitorY
            screen: modelData
            // Decode the frozen frame off the GUI thread; map the surface once it can show the frame.
            visible: root.opened && frozenFrame.status === Image.Ready && !!monitor
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "omashot-capture-selector"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            color: Theme.window
            onVisibleChanged: {
                if (visible)
                    Qt.callLater(function () {
                        keyReceiver.forceActiveFocus();
                    });
            }
            Item {
                id: keyReceiver
                anchors.fill: parent
                clip: true
                focus: true
                Keys.onPressed: function (event) {
                    root.key(event);
                }
                Image {
                    id: frozenFrame
                    x: root.originX - surface.monitorX
                    y: root.originY - surface.monitorY
                    width: Number(root.snapshot.width || 0) / root.imageScale
                    height: Number(root.snapshot.height || 0) / root.imageScale
                    source: root.snapshot.path ? "file://" + root.snapshot.path : ""
                    fillMode: Image.Stretch
                    asynchronous: true
                    cache: true
                    smooth: false
                }
                Rectangle {
                    anchors.fill: parent
                    visible: !root.hasSelection
                    color: Theme.alpha(Theme.darkest, 0.07)
                }
                Item {
                    visible: root.hasSelection
                    anchors.fill: parent
                    Rectangle {
                        x: 0
                        y: 0
                        width: parent.width
                        height: Math.max(0, Math.min(parent.height, surface.topEdge))
                        color: Theme.scrim
                    }
                    Rectangle {
                        x: 0
                        y: Math.max(0, surface.topEdge + root.selectionHeight)
                        width: parent.width
                        height: Math.max(0, parent.height - y)
                        color: Theme.scrim
                    }
                    Rectangle {
                        x: 0
                        y: Math.max(0, surface.topEdge)
                        width: Math.max(0, Math.min(parent.width, surface.leftEdge))
                        height: Math.max(0, Math.min(parent.height, surface.topEdge + root.selectionHeight) - y)
                        color: Theme.scrim
                    }
                    Rectangle {
                        x: Math.max(0, surface.leftEdge + root.selectionWidth)
                        y: Math.max(0, surface.topEdge)
                        width: Math.max(0, parent.width - x)
                        height: Math.max(0, Math.min(parent.height, surface.topEdge + root.selectionHeight) - y)
                        color: Theme.scrim
                    }
                    Rectangle {
                        x: surface.leftEdge
                        y: surface.topEdge
                        width: root.selectionWidth
                        height: root.selectionHeight
                        color: "transparent"
                        border.width: 1
                        border.color: Theme.accent
                    }
                }
                Item {
                    visible: root.showCrosshair && surface.pointerHere
                    anchors.fill: parent
                    Rectangle {
                        x: surface.localPointerX
                        width: 1
                        height: parent.height
                        color: Theme.danger
                        opacity: 0.75
                    }
                    Rectangle {
                        y: surface.localPointerY
                        height: 1
                        width: parent.width
                        color: Theme.danger
                        opacity: 0.75
                    }
                }
                MouseArea {
                    id: selectorMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    preventStealing: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.CrossCursor
                    onPressed: function (event) {
                        keyReceiver.forceActiveFocus();
                        if (event.button === Qt.RightButton) {
                            root.reject();
                            return;
                        }
                        root.begin(surface.monitorX + event.x, surface.monitorY + event.y);
                    }
                    onPositionChanged: function (event) {
                        root.update(surface.monitorX + event.x, surface.monitorY + event.y);
                    }
                    onReleased: root.end()
                    onCanceled: root.abort()
                }
                Rectangle {
                    id: magnifier
                    visible: root.showMagnifier && surface.pointerHere
                    readonly property int zoom: 8
                    width: 140
                    height: 140
                    radius: 8
                    x: surface.localPointerX + 28 + width < surface.width - 10 ? surface.localPointerX + 28 : surface.localPointerX - width - 28
                    y: surface.localPointerY + 28 + height < surface.height - 10 ? surface.localPointerY + 28 : surface.localPointerY - height - 28
                    color: Theme.window
                    border.width: 2
                    border.color: Theme.accent
                    clip: true
                    Image {
                        x: magnifier.width / 2 - (Math.floor((root.pointerX - root.originX) * root.imageScale) + 0.5) * magnifier.zoom
                        y: magnifier.height / 2 - (Math.floor((root.pointerY - root.originY) * root.imageScale) + 0.5) * magnifier.zoom
                        width: Number(root.snapshot.width || 0) * magnifier.zoom
                        height: Number(root.snapshot.height || 0) * magnifier.zoom
                        source: root.snapshot.path ? "file://" + root.snapshot.path : ""
                        fillMode: Image.Stretch
                        asynchronous: true
                        cache: true
                        smooth: false
                    }
                    Rectangle {
                        x: parent.width / 2 - 1
                        width: 2
                        height: parent.height
                        color: Theme.danger
                        opacity: 0.7
                    }
                    Rectangle {
                        y: parent.height / 2 - 1
                        height: 2
                        width: parent.width
                        color: Theme.danger
                        opacity: 0.7
                    }
                    Rectangle {
                        x: parent.width / 2 - 4
                        y: parent.height / 2 - 4
                        width: 8
                        height: 8
                        color: "transparent"
                        border.color: Theme.lightest
                    }
                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        radius: 8
                        border.width: 2
                        border.color: Theme.accent
                    }
                }
                Rectangle {
                    visible: surface.pointerHere
                    x: root.clamp(surface.localPointerX + 24, 8, surface.width - width - 8)
                    y: surface.localPointerY > 45 ? surface.localPointerY - 34 : surface.localPointerY + 12
                    implicitWidth: coordinates.implicitWidth + 16
                    implicitHeight: 25
                    radius: 6
                    color: Theme.alpha(Theme.window, 0.92)
                    Text {
                        id: coordinates
                        anchors.centerIn: parent
                        text: root.hasSelection ? root.pixelWidth + " × " + root.pixelHeight + " px" : Math.round(root.pointerX) + ", " + Math.round(root.pointerY)
                        color: Theme.text
                        font.pixelSize: 11
                    }
                }
                Rectangle {
                    anchors.top: parent.top
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.topMargin: 22
                    visible: !root.hasSelection
                    implicitWidth: hint.implicitWidth + 28
                    implicitHeight: 33
                    radius: 9
                    color: Theme.alpha(Theme.window, 0.92)
                    Text {
                        id: hint
                        anchors.centerIn: parent
                        text: "Drag to capture · Esc to cancel"
                        color: Theme.textSoft
                        font.pixelSize: 12
                    }
                }
            }
        }
    }
}
