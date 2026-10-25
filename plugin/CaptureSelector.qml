import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
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
    property rect initialSelection: Qt.rect(0, 0, 0, 0)
    property string resizeHandle: ""
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
    function contains(x, y) {
        return hasSelection && x >= selectionX && y >= selectionY && x <= selectionX + selectionWidth && y <= selectionY + selectionHeight;
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
        initialSelection = Qt.rect(selectionX, selectionY, selectionWidth, selectionHeight);
        if (contains(x, y))
            interaction = "move";
        else {
            interaction = "draw";
            selectionX = pressX;
            selectionY = pressY;
            selectionWidth = 0;
            selectionHeight = 0;
        }
    }
    function resizeBegin(handle, x, y) {
        if (!opened || !hasSelection || completing)
            return;
        pointerX = x;
        pointerY = y;
        pressX = x;
        pressY = y;
        resizeHandle = handle;
        interaction = "resize";
        initialSelection = Qt.rect(selectionX, selectionY, selectionWidth, selectionHeight);
    }
    function update(x, y) {
        pointerX = x;
        pointerY = y;
        if (completing)
            return;
        var gx = Math.round(clamp(x, originX, originX + logicalWidth)), gy = Math.round(clamp(y, originY, originY + logicalHeight));
        if (interaction === "draw") {
            selectionX = Math.min(pressX, gx);
            selectionY = Math.min(pressY, gy);
            selectionWidth = Math.abs(gx - pressX);
            selectionHeight = Math.abs(gy - pressY);
        } else if (interaction === "move") {
            selectionX = Math.round(clamp(initialSelection.x + gx - pressX, originX, originX + logicalWidth - selectionWidth));
            selectionY = Math.round(clamp(initialSelection.y + gy - pressY, originY, originY + logicalHeight - selectionHeight));
        } else if (interaction === "resize") {
            var left = initialSelection.x, right = left + initialSelection.width, top = initialSelection.y, bottom = top + initialSelection.height;
            if (resizeHandle.indexOf("w") >= 0)
                left = clamp(Math.round(initialSelection.x + x - pressX), originX, right - 1);
            if (resizeHandle.indexOf("e") >= 0)
                right = clamp(Math.round(initialSelection.x + initialSelection.width + x - pressX), left + 1, originX + logicalWidth);
            if (resizeHandle.indexOf("n") >= 0)
                top = clamp(Math.round(initialSelection.y + y - pressY), originY, bottom - 1);
            if (resizeHandle.indexOf("s") >= 0)
                bottom = clamp(Math.round(initialSelection.y + initialSelection.height + y - pressY), top + 1, originY + logicalHeight);
            selectionX = left;
            selectionY = top;
            selectionWidth = right - left;
            selectionHeight = bottom - top;
        }
    }
    function end() {
        interaction = "";
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
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            finish();
            event.accepted = true;
        } else if (hasSelection && [Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down].indexOf(event.key) >= 0) {
            var step = event.modifiers & Qt.ShiftModifier ? 10 : 1;
            var dx = event.key === Qt.Key_Left ? -step : event.key === Qt.Key_Right ? step : 0;
            var dy = event.key === Qt.Key_Up ? -step : event.key === Qt.Key_Down ? step : 0;
            if (event.modifiers & Qt.ControlModifier) {
                selectionWidth = clamp(selectionWidth + dx, 1, originX + logicalWidth - selectionX);
                selectionHeight = clamp(selectionHeight + dy, 1, originY + logicalHeight - selectionY);
            } else {
                selectionX = clamp(selectionX + dx, originX, originX + logicalWidth - selectionWidth);
                selectionY = clamp(selectionY + dy, originY, originY + logicalHeight - selectionHeight);
            }
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
            visible: root.opened && !!root.snapshot.path && !!monitor
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
                    x: root.originX - surface.monitorX
                    y: root.originY - surface.monitorY
                    width: Number(root.snapshot.width || 0) / root.imageScale
                    height: Number(root.snapshot.height || 0) / root.imageScale
                    source: root.snapshot.path ? "file://" + root.snapshot.path : ""
                    fillMode: Image.Stretch
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
                    visible: root.showCrosshair && surface.pointerHere && (!root.hasSelection || root.interaction !== "")
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
                    cursorShape: root.contains(surface.monitorX + mouseX, surface.monitorY + mouseY) ? Qt.SizeAllCursor : Qt.CrossCursor
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
                    onCanceled: root.end()
                }
                Repeater {
                    model: ["nw", "n", "ne", "e", "se", "s", "sw", "w"]
                    Item {
                        id: handle
                        required property string modelData
                        readonly property real hx: modelData.indexOf("w") >= 0 ? root.selectionX : modelData.indexOf("e") >= 0 ? root.selectionX + root.selectionWidth : root.selectionX + root.selectionWidth / 2
                        readonly property real hy: modelData.indexOf("n") >= 0 ? root.selectionY : modelData.indexOf("s") >= 0 ? root.selectionY + root.selectionHeight : root.selectionY + root.selectionHeight / 2
                        visible: root.hasSelection && root.interaction !== "draw"
                        x: hx - surface.monitorX - width / 2
                        y: hy - surface.monitorY - height / 2
                        width: 20
                        height: 20
                        Rectangle {
                            anchors.centerIn: parent
                            width: 8
                            height: 8
                            radius: 4
                            color: Theme.lightest
                            border.color: Theme.accent
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: handle.modelData === "n" || handle.modelData === "s" ? Qt.SizeVerCursor : handle.modelData === "e" || handle.modelData === "w" ? Qt.SizeHorCursor : handle.modelData === "nw" || handle.modelData === "se" ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
                            onPressed: function (event) {
                                root.resizeBegin(handle.modelData, surface.monitorX + handle.x + event.x, surface.monitorY + handle.y + event.y);
                            }
                            onPositionChanged: function (event) {
                                if (pressed)
                                    root.update(surface.monitorX + handle.x + event.x, surface.monitorY + handle.y + event.y);
                            }
                            onReleased: root.end()
                            onCanceled: root.end()
                        }
                    }
                }
                Rectangle {
                    id: magnifier
                    visible: root.showMagnifier && surface.pointerHere && (!root.hasSelection || root.interaction === "draw" || root.interaction === "resize")
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
                    visible: surface.pointerHere && (!root.hasSelection || root.interaction !== "")
                    x: root.clamp(surface.localPointerX + 24, 8, surface.width - width - 8)
                    y: surface.localPointerY > 45 ? surface.localPointerY - 34 : surface.localPointerY + 12
                    implicitWidth: coordinates.implicitWidth + 16
                    implicitHeight: 25
                    radius: 6
                    color: Theme.alpha(Theme.window, 0.92)
                    Text {
                        id: coordinates
                        anchors.centerIn: parent
                        text: Math.round(root.pointerX) + ", " + Math.round(root.pointerY)
                        color: Theme.text
                        font.pixelSize: 11
                    }
                }
                Rectangle {
                    id: actions
                    visible: root.hasSelection && root.ownerName() === surface.modelData.name && root.interaction === ""
                    implicitWidth: actionRow.implicitWidth + 16
                    implicitHeight: 44
                    radius: 10
                    color: Theme.alpha(Theme.panel, 0.94)
                    border.color: Theme.border
                    x: root.clamp(surface.leftEdge + root.selectionWidth / 2 - width / 2, 10, surface.width - width - 10)
                    y: surface.topEdge + root.selectionHeight + height + 12 < surface.height ? surface.topEdge + root.selectionHeight + 12 : surface.topEdge - height - 12 > 10 ? surface.topEdge - height - 12 : root.clamp(surface.topEdge + 16, 10, surface.height - height - 10)
                    RowLayout {
                        id: actionRow
                        anchors.centerIn: parent
                        spacing: 8
                        Text {
                            text: root.pixelWidth + " × " + root.pixelHeight + " px"
                            color: Theme.text
                            font.pixelSize: 12
                            leftPadding: 4
                            rightPadding: 8
                        }
                        IconButton {
                            iconName: "close"
                            text: "Cancel · Esc"
                            size: 32
                            onClicked: root.reject()
                        }
                        IconButton {
                            iconName: "check"
                            text: "Capture selected area · Enter"
                            size: 32
                            selected: true
                            onClicked: root.finish()
                        }
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
                        text: "Drag to select · Enter to capture · Esc to cancel"
                        color: Theme.textSoft
                        font.pixelSize: 12
                    }
                }
            }
        }
    }
}
