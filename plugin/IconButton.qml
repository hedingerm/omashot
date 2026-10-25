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
        color: !root.enabled ? "#637087" : root.selected || root.checked ? "#ffffff" : "#dce4f0"
    }
    background: Rectangle {
        radius: 8
        color: root.down ? "#6959cc" : root.selected || root.checked ? "#6251c4" : root.hovered ? "#30384d" : "transparent"
        border.width: root.activeFocus ? 1 : 0
        border.color: "#b5a8ff"
        opacity: root.enabled ? 1 : 0.5
        Behavior on color { ColorAnimation { duration: 100 } }
    }
}
