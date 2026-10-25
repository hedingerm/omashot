import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

ShellRoot {
    id: root
    property var selected: Hyprland.toplevels.values.find(function (t) {
        return t.address.replace("0x", "") === Quickshell.env("OMASHOT_WINDOW_ADDRESS").replace("0x", "");
    }) || null
    property bool saved: false
    PanelWindow {
        id: window
        mask: Region {}
        implicitWidth: 1
        implicitHeight: 1
        color: "transparent"
        anchors {
            left: true
            bottom: true
        }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.namespace: "omashot-window-export"
        ScreencopyView {
            id: copy
            captureSource: root.selected ? root.selected.wayland : null
            live: false
            paintCursor: Quickshell.env("OMASHOT_WINDOW_CURSOR") === "1"
            width: sourceSize.width / window.devicePixelRatio
            height: sourceSize.height / window.devicePixelRatio
            onHasContentChanged: {
                if (hasContent && !root.saved) {
                    root.saved = true;
                    Qt.callLater(function () {
                        copy.grabToImage(function (result) {
                            console.log("CAPTURE_SOURCE=" + JSON.stringify({
                                width: copy.sourceSize.width,
                                height: copy.sourceSize.height,
                                devicePixelRatio: window.devicePixelRatio
                            }));
                            console.log("CAPTURE_SAVED=" + result.saveToFile(Quickshell.env("OMASHOT_WINDOW_OUTPUT")));
                            Qt.quit();
                        }, Qt.size(Math.round(copy.sourceSize.width / window.devicePixelRatio), Math.round(copy.sourceSize.height / window.devicePixelRatio)));
                    });
                }
            }
        }
    }
    Timer {
        interval: 7000
        running: true
        onTriggered: {
            console.error("Window export timed out");
            Qt.quit();
        }
    }
}
