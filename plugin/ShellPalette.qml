import QtQuick
import qs.Commons as Commons

// Loaded by Theme only inside omarchy-shell, where qs.Commons exists; deliberately not in qmldir.
QtObject {
    signal changed
    function notify() {
        changed();
    }
    readonly property color background: Commons.Color.background
    readonly property color foreground: Commons.Color.foreground
    readonly property color accent: Commons.Color.accent
    readonly property color urgent: Commons.Color.urgent
    onBackgroundChanged: Qt.callLater(notify)
    onForegroundChanged: Qt.callLater(notify)
    onAccentChanged: Qt.callLater(notify)
    onUrgentChanged: Qt.callLater(notify)
}
