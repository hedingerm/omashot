import QtQuick
import Quickshell
import Quickshell.Io

Item {
    property var shell: null
    property var manifest: null
    readonly property string backend: Quickshell.env("OMASHOT_BACKEND") || (Quickshell.env("HOME") + "/.local/bin/omashot")
    Process {
        id: cleanup
        command: [backend, "cleanup"]
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim())
                    console.warn("OmaShot history cleanup:", text.trim());
            }
        }
    }
    Timer {
        interval: 3600000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            if (!cleanup.running)
                cleanup.running = true;
        }
    }
}
