import QtQuick
import qs.Commons as Commons

// Loaded by Theme only inside omarchy-shell, where qs.Commons exists; deliberately not in qmldir.
QtObject {
    // Emitted synchronously so OmaShot starts fading in the same tick as the bar; repeated
    // calls while loadColors() sets each role just retarget the same animation.
    signal changed
    readonly property color background: Commons.Color.background
    readonly property color foreground: Commons.Color.foreground
    readonly property color accent: Commons.Color.accent
    readonly property color urgent: Commons.Color.urgent
    onBackgroundChanged: changed()
    onForegroundChanged: changed()
    onAccentChanged: changed()
    onUrgentChanged: changed()
}
