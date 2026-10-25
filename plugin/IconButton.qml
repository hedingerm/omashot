import QtQuick
import QtQuick.Controls

Button {
    id: root
    property string iconName: "more"
    property bool selected: false
    property int size: 36
    property int iconSize: 20
    implicitWidth: size
    implicitHeight: size
    padding: 8
    hoverEnabled: true
    Accessible.name: text
    Accessible.description: text
    ToolTip.visible: hovered && text.length > 0
    ToolTip.text: text
    ToolTip.delay: 500
    contentItem: Icon {
        name: root.iconName
        size: root.iconSize
        color: !root.enabled ? Theme.textDisabled : root.selected || root.checked ? Theme.accentText : Theme.text
    }
    background: Rectangle {
        radius: Theme.radius(8)
        color: root.down ? Theme.accentPressed : root.selected || root.checked ? Theme.accent : root.hovered ? Theme.raised : "transparent"
        border.width: root.activeFocus ? 1 : 0
        border.color: Theme.accentHover
        opacity: root.enabled ? 1 : 0.5
        Behavior on color { ColorAnimation { duration: 100 } }
    }
}
