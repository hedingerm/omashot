import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Omarchy bar entry: left click opens the launcher, middle click captures an area, right click
// opens a menu of every capture mode with its Hyprland binding. Loaded only inside omarchy-shell,
// where qs.Ui exists; deliberately not in qmldir. Chrome follows the shell's popup palette.
BarWidget {
    id: root
    moduleName: "omashot"
    readonly property string launcher: Quickshell.env("OMASHOT_UI") || (Quickshell.env("HOME") + "/.local/bin/omashot-ui")
    readonly property var actions: [
        { mode: "region", icon: "capture", text: "Capture area" },
        { mode: "window", icon: "window", text: "Capture window" },
        { mode: "active", icon: "window", text: "Capture active window" },
        { mode: "fullscreen", icon: "screen", text: "Capture full screen" },
        { mode: "repeat", icon: "reset", text: "Repeat last area" },
        { mode: "scroll", icon: "resize", text: "Scrolling capture" },
        { mode: "ocr", icon: "ocr", text: "Capture text" },
        { mode: "qr", icon: "qr", text: "Read QR from screen" },
        { separator: true },
        { mode: "open", icon: "expand", text: "Open OmaShot" },
        { mode: "history", icon: "history", text: "History and editor" },
        { mode: "preferences", icon: "settings", text: "Preferences" }
    ]
    property var hotkeys: ({})
    property string pendingMode: ""

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    // The bar closes the previous popout through its owner when another one opens.
    function close() {
        menu.open = false;
    }
    function run(mode) {
        close();
        // The menu fades out in 120 ms; grim must not catch it.
        pendingMode = mode;
        launchTimer.restart();
    }
    // Hyprland modmask bits: SHIFT 1, CTRL 4, ALT 8, SUPER 64.
    function chord(bind) {
        let mods = [[64, "Super"], [4, "Ctrl"], [8, "Alt"], [1, "Shift"]].filter(m => bind.modmask & m[0]).map(m => m[1]);
        let key = String(bind.key || "");
        return mods.concat([key.length === 1 ? key.toUpperCase() : key]).join("+");
    }
    function readHotkeys(text) {
        let found = {};
        try {
            for (const bind of JSON.parse(text)) {
                let arg = String(bind.arg || ""), m = arg.match(/\bomashot-ui(?:\s+([a-z]+))?\s*$/) || arg.match(/\bomarchy-shell\s+omashot\s+(?:capture\s+)?([a-z]+)\s*$/);
                let mode = m ? (m[1] || "open") : "";
                if (mode && !found[mode] && bind.key)
                    found[mode] = chord(bind);
            }
        } catch (error) {}
        hotkeys = found;
    }

    Timer {
        id: launchTimer
        interval: 160
        onTriggered: Quickshell.execDetached([root.launcher, root.pendingMode])
    }
    // Read on every open rather than polling: bindings change only when the user edits them.
    Process {
        id: binds
        command: ["hyprctl", "binds", "-j"]
        stdout: StdioCollector {
            onStreamFinished: root.readHotkeys(text)
        }
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        tooltipText: menu.open ? "" : "OmaShot"
        iconComponent: Component {
            Icon {
                name: "capture"
                size: Style.bar.iconCanvas
                color: button.foreground
            }
        }
        onPressed: function (b) {
            if (b === Qt.RightButton) {
                if (!menu.open)
                    binds.running = true;
                menu.open = !menu.open;
            } else
                root.run(b === Qt.MiddleButton ? "region" : "open");
        }
    }

    PopupCard {
        id: menu
        anchorItem: button
        bar: root.bar
        owner: root
        padding: Style.space(6)
        contentWidth: Style.space(280)
        contentHeight: fittedContentHeight(items.implicitHeight)

        Column {
            id: items
            width: parent.width
            Repeater {
                model: root.actions
                delegate: Item {
                    id: row
                    required property var modelData
                    width: items.width
                    height: modelData.separator ? Style.space(9) : Style.space(30)
                    Rectangle {
                        visible: row.modelData.separator === true
                        anchors.centerIn: parent
                        width: parent.width - Style.space(12)
                        height: 1
                        color: Commons.Color.popups.border
                        opacity: 0.35
                    }
                    Rectangle {
                        visible: !row.modelData.separator
                        anchors.fill: parent
                        radius: Style.cornerRadius
                        color: area.containsMouse ? Commons.Color.menu.selectedBackground : "transparent"
                    }
                    Icon {
                        visible: !row.modelData.separator
                        name: row.modelData.icon || "more"
                        size: Style.font.iconLarge
                        color: area.containsMouse ? Commons.Color.menu.selectedText : Commons.Color.popups.text
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        visible: !row.modelData.separator
                        text: row.modelData.text || ""
                        color: area.containsMouse ? Commons.Color.menu.selectedText : Commons.Color.popups.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(8) + Style.font.iconLarge + Style.space(10)
                        anchors.right: shortcut.left
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                    }
                    Text {
                        id: shortcut
                        visible: !row.modelData.separator
                        text: root.hotkeys[row.modelData.mode] || ""
                        color: Commons.Color.popups.text
                        opacity: 0.6
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    MouseArea {
                        id: area
                        anchors.fill: parent
                        enabled: !row.modelData.separator
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.run(row.modelData.mode)
                    }
                }
            }
        }
    }
}
