// Offscreen harness for docs/screenshots/editor.png. Run by scripts/screenshots.sh.
import QtQuick
import Quickshell
ShellRoot {
    FloatingWindow {
        implicitWidth: 1440; implicitHeight: 900; visible: true; color: "#11131c"
        Editor {
            id: edit; anchors.fill: parent
            sourcePath: Quickshell.env("OMASHOT_SOURCE")
            backend: Quickshell.env("OMASHOT_BACKEND")
        }
        Timer {
            interval: 80; running: true; repeat: true
            property int phase: 0
            onTriggered: {
                if (edit.busy || !edit.previewReady) return
                if (phase === 0) {
                    var ops = JSON.parse(Quickshell.env("OMASHOT_OPS")), background = null
                    for (var i = 0; i < ops.length; i++) {
                        if (ops[i].type === "background") background = ops[i]
                        else edit.add(ops[i])
                    }
                    if (background) {
                        var panel = edit.backgroundControl
                        panel.selectGradient(background.preset);
                        var keys = ["padding", "radius", "inset", "shadow_strength"]
                        keys.forEach(function(key) {
                            if (background[key] !== undefined) panel.update(key, background[key])
                        })
                    }
                    edit.tool = "arrow"
                    phase = 1
                } else if (phase < 12) {
                    phase++
                } else if (phase === 12) {
                    phase = 13
                    edit.grabToImage(function(image) {
                        console.log(image.saveToFile(Quickshell.env("OMASHOT_SCREENSHOT")) ? "SHOT_SAVED" : "SHOT_FAILED")
                        Qt.quit()
                    })
                }
            }
        }
        Timer { interval: 40000; running: true; onTriggered: { console.error("SHOT_TIMEOUT"); Qt.quit() } }
    }
}
