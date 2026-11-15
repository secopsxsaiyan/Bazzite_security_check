// Security Check - commands or other fixed-width text: read-only, can be
// selected, with a Copy button.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Rectangle {
    id: block
    property string text: ""
    Layout.fillWidth: true
    implicitHeight: edit.implicitHeight + Kirigami.Units.largeSpacing * 2
    radius: Kirigami.Units.cornerRadius
    color: Kirigami.Theme.backgroundColor
    border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.2)
    Kirigami.Theme.colorSet: Kirigami.Theme.View
    Kirigami.Theme.inherit: false

    TextEdit {
        id: edit
        anchors.left: parent.left; anchors.right: copy.left; anchors.top: parent.top
        anchors.margins: Kirigami.Units.largeSpacing
        readOnly: true; selectByMouse: true
        wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText
        font: Kirigami.Theme.fixedWidthFont
        color: Kirigami.Theme.textColor
        selectionColor: Kirigami.Theme.highlightColor
        selectedTextColor: Kirigami.Theme.highlightedTextColor
        text: block.text
        Accessible.role: Accessible.StaticText
        Accessible.name: block.text
    }
    QQC2.ToolButton {
        id: copy
        anchors.right: parent.right; anchors.top: parent.top
        anchors.margins: Kirigami.Units.smallSpacing
        icon.name: "edit-copy"
        display: QQC2.AbstractButton.IconOnly
        text: qsTr("Copy")
        QQC2.ToolTip.text: text
        QQC2.ToolTip.visible: hovered
        Accessible.name: text
        onClicked: { edit.selectAll(); edit.copy(); edit.deselect() }
    }
}
