import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

Item {
    id: root
    property var captures: []
    property bool opened: false
    property bool suspended: false
    property bool collapsed: false
    property string corner: "bottom-right"
    property string outputName: "active"
    property int thumbnailWidth: 160
    property int timeoutSeconds: 0
    property bool dismissAfterDrop: true
    property string pendingCopy: ""
    property string copiedPath: ""
    readonly property var targetScreen: {
        let name = outputName === "active" ? (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "") : outputName;
        return Quickshell.screens.find(function (s) {
            return s.name === name;
        }) || Quickshell.screens[0];
    }
    signal copyRequested(string path)
    signal saveRequested(string path)
    signal annotateRequested(string path)
    signal pinRequested(string path)
    signal dismissRequested(int id)
    signal historyRequested
    function restore() {
        collapsed = false;
    }
    function hideTemporarily() {
        collapsed = true;
    }
    function confirmCopy() {
        copiedPath = pendingCopy;
        copiedTimer.restart();
    }
    Timer {
        id: copiedTimer
        interval: 1400
        onTriggered: root.copiedPath = ""
    }
    component CornerButton: IconButton {
        size: 28
        iconSize: 16
        background: Rectangle {
            radius: width / 2
            color: parent.hovered ? Theme.raised : Theme.alpha(Theme.window, 0.92)
        }
        contentItem: Icon {
            name: parent.iconName
            size: 16
            color: Theme.text
        }
    }
    PanelWindow {
        id: stackWindow
        screen: root.targetScreen
        visible: root.opened && !root.suspended && !root.collapsed && root.captures.length > 0
        anchors {
            left: root.corner.includes("left")
            right: root.corner.includes("right")
            top: root.corner.includes("top")
            bottom: root.corner.includes("bottom")
        }
        margins {
            left: 20
            right: 20
            top: 30
            bottom: 20
        }
        implicitWidth: Math.max(100, Math.min(320, root.thumbnailWidth)) + 16
        implicitHeight: Math.min(stack.implicitHeight + 16, (screen ? screen.height : 1000) - 80)
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "omashot-quick-access"
        color: "transparent"
        Flickable {
            anchors.fill: parent
            anchors.margins: 8
            contentWidth: width
            contentHeight: stack.implicitHeight
            interactive: contentHeight > height
            clip: true
            Column {
                id: stack
                width: parent.width
                spacing: 10
                Repeater {
                    model: root.captures
                    delegate: Rectangle {
                        id: card
                        required property var modelData
                        property bool preparingDrag: false
                        readonly property bool showActions: hover.hovered && !preparingDrag && !dragArea.drag.active
                        width: stack.width
                        height: Math.max(96, Math.min(width * 0.85, width * Math.max(1, modelData.height || 90) / Math.max(1, modelData.width || 160)))
                        radius: 9
                        color: Theme.surface
                        border.width: 1
                        border.color: hover.hovered ? Theme.accent : Theme.border
                        clip: true
                        Accessible.name: "Screenshot preview"
                        HoverHandler {
                            id: hover
                        }
                        Image {
                            id: thumb
                            anchors.fill: parent
                            anchors.margins: 1
                            source: "file://" + card.modelData.path
                            fillMode: Image.PreserveAspectFit
                            sourceSize.width: root.thumbnailWidth * 2
                            asynchronous: true
                            visible: false
                        }
                        Rectangle {
                            id: cardMask
                            anchors.fill: thumb
                            radius: 8
                            color: "white"
                            layer.enabled: true
                            visible: false
                        }
                        MultiEffect {
                            anchors.fill: thumb
                            source: thumb
                            maskEnabled: true
                            maskSource: cardMask
                            blurEnabled: card.showActions
                            blur: 0.8
                            blurMax: 24
                        }
                        Rectangle {
                            anchors.fill: parent
                            color: Theme.alpha(Theme.window, 0.6)
                            visible: card.showActions
                        }
                        MouseArea {
                            id: dragArea
                            anchors.fill: parent
                            drag.target: dragProxy
                            onPressed: {
                                card.preparingDrag = true;
                                card.grabToImage(function (result) {
                                    card.Drag.imageSource = result.url;
                                    card.preparingDrag = false;
                                });
                            }
                            onDoubleClicked: root.annotateRequested(card.modelData.path)
                        }
                        Item {
                            id: dragProxy
                        }
                        Drag.active: dragArea.drag.active
                        Drag.dragType: Drag.Automatic
                        Drag.supportedActions: Qt.CopyAction
                        Drag.mimeData: ({
                                "text/uri-list": "file://" + card.modelData.path
                            })
                        Drag.onDragFinished: function (action) {
                            if (action !== Qt.IgnoreAction && root.dismissAfterDrop)
                                root.dismissRequested(card.modelData.id);
                        }
                        Column {
                            anchors.centerIn: parent
                            spacing: 6
                            visible: card.showActions
                            Button {
                                text: root.copiedPath === card.modelData.path ? "Copied" : "Copy"
                                implicitWidth: 72
                                implicitHeight: 30
                                padding: 4
                                background: Rectangle {
                                    radius: 15
                                    color: parent.hovered ? Theme.accentHover : Theme.accent
                                }
                                contentItem: Text {
                                    text: parent.text
                                    font.pixelSize: 13
                                    font.weight: Font.Medium
                                    color: Theme.accentText
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                onClicked: {
                                    root.pendingCopy = card.modelData.path;
                                    root.copyRequested(card.modelData.path);
                                }
                            }
                            Button {
                                text: "Save"
                                implicitWidth: 72
                                implicitHeight: 30
                                padding: 4
                                background: Rectangle {
                                    radius: 15
                                    color: parent.hovered ? Theme.accentHover : Theme.accent
                                }
                                contentItem: Text {
                                    text: parent.text
                                    font.pixelSize: 13
                                    font.weight: Font.Medium
                                    color: Theme.accentText
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                onClicked: root.saveRequested(card.modelData.path)
                            }
                        }
                        CornerButton {
                            anchors {
                                left: parent.left
                                top: parent.top
                                margins: 5
                            }
                            iconName: "close"
                            text: "Dismiss this preview"
                            visible: card.showActions
                            onClicked: root.dismissRequested(card.modelData.id)
                        }
                        CornerButton {
                            anchors {
                                right: parent.right
                                top: parent.top
                                margins: 5
                            }
                            iconName: "pin"
                            text: "Pin screenshot"
                            visible: card.showActions
                            onClicked: root.pinRequested(card.modelData.path)
                        }
                        CornerButton {
                            anchors {
                                left: parent.left
                                bottom: parent.bottom
                                margins: 5
                            }
                            iconName: "text"
                            text: "Annotate"
                            visible: card.showActions
                            onClicked: root.annotateRequested(card.modelData.path)
                        }
                        CornerButton {
                            anchors {
                                right: parent.right
                                bottom: parent.bottom
                                margins: 5
                            }
                            iconName: "chevron"
                            text: "Temporarily hide previews"
                            visible: card.showActions
                            onClicked: root.hideTemporarily()
                        }
                        Timer {
                            interval: Math.max(1, root.timeoutSeconds) * 1000
                            running: root.timeoutSeconds > 0 && root.opened && !root.suspended && !root.collapsed && !hover.hovered && !dragArea.drag.active && !card.preparingDrag
                            onTriggered: root.dismissRequested(card.modelData.id)
                        }
                    }
                }
            }
        }
    }
    PanelWindow {
        screen: root.targetScreen
        visible: root.opened && root.collapsed && !root.suspended && root.captures.length > 0
        anchors {
            left: root.corner.includes("left")
            right: root.corner.includes("right")
            bottom: true
        }
        margins {
            left: 28
            right: 28
        }
        implicitWidth: Math.min(root.thumbnailWidth, 140)
        implicitHeight: 26
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "omashot-quick-access-handle"
        color: "transparent"
        Rectangle {
            anchors.fill: parent
            radius: 9
            color: Theme.alpha(Theme.panel, 0.9)
            border.color: Theme.borderStrong
            Row {
                anchors.centerIn: parent
                spacing: 6
                Icon {
                    name: "chevron"
                    size: 14
                    rotation: 180
                    color: Theme.text
                }
                Text {
                    text: String(root.captures.length)
                    color: Theme.text
                    font.pixelSize: 11
                }
            }
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.restore()
                onClicked: root.restore()
            }
        }
    }
}
