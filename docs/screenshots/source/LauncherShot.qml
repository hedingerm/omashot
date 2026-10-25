// Offscreen harness for docs/screenshots/launcher.png. Run by scripts/screenshots.sh.
import QtQuick
import Quickshell
ShellRoot {
    Main { id: main }
    Timer {
        interval: 100; running: true; repeat: true
        property int phase: 0
        property var frame: null
        function launcherWindow() {
            for (var i = 0; i < main.data.length; i++)
                if (main.data[i] && main.data[i].contentItem !== undefined) return main.data[i]
            return null
        }
        onTriggered: {
            var window = launcherWindow()
            if (phase === 0) {
                if (!window) return
                main.open("{}")
                phase = 1
            } else if (phase === 1) {
                // The compositor decides the real window size (it may tile it), so move the layout
                // onto a fixed-size backdrop in the window color; grabToImage renders it regardless.
                var layout = window.contentItem.children[0]
                frame = Qt.createQmlObject('import QtQuick; Rectangle { width: 940; height: 640 }', window.contentItem)
                frame.color = window.color
                layout.anchors.fill = undefined
                layout.parent = frame
                layout.width = frame.width; layout.height = frame.height
                phase = 2
            } else if (phase < 15) {
                phase++
            } else if (phase === 15) {
                phase = 16
                frame.grabToImage(function(image) {
                    console.log(image.saveToFile(Quickshell.env("OMASHOT_SCREENSHOT")) ? "SHOT_SAVED" : "SHOT_FAILED")
                    Qt.quit()
                })
            }
        }
    }
    Timer { interval: 30000; running: true; onTriggered: { console.error("SHOT_TIMEOUT"); Qt.quit() } }
}
