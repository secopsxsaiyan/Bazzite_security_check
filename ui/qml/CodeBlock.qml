// Security Check - commands or other fixed-width text: read-only, can be
// selected with the mouse or the keyboard (Tab to it, Ctrl+A, Shift+arrows,
// Ctrl+C), with a Copy button. With the keyboard focus in it the text
// shows its cursor, which the arrow keys, Home and End move, and the page
// scrolls along with the cursor.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

Rectangle {
    id: block
    property string text: ""
    // The scrolling area it is in, if any: the text comes into view when it
    // gets the keyboard focus.
    property Flickable flickable: null
    Layout.fillWidth: true
    implicitHeight: edit.implicitHeight + Kirigami.Units.largeSpacing * 2
    radius: Kirigami.Units.cornerRadius
    color: Kirigami.Theme.backgroundColor
    border.color: Qt.alpha(Kirigami.Theme.textColor, 0.2)
    Kirigami.Theme.colorSet: Kirigami.Theme.View
    Kirigami.Theme.inherit: false

    TextEdit {
        id: edit
        anchors.left: parent.left; anchors.right: copy.left; anchors.top: parent.top
        anchors.margins: Kirigami.Units.largeSpacing
        readOnly: true; selectByMouse: true; selectByKeyboard: true
        activeFocusOnTab: true
        wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText
        font: Kirigami.Theme.fixedWidthFont
        color: Kirigami.Theme.textColor
        selectionColor: Kirigami.Theme.highlightColor
        selectedTextColor: Kirigami.Theme.highlightedTextColor
        text: block.text
        onActiveFocusChanged: {
            // Read-only text shows no cursor by itself.
            cursorVisible = activeFocus
            if (activeFocus) Util.reveal(block.flickable, block, Kirigami.Units.gridUnit)
            else deselect()
        }
        // The line the cursor is on stays in view.
        onCursorRectangleChanged: if (activeFocus) Util.reveal(block.flickable, cursorLine, Kirigami.Units.gridUnit)
        Item {
            id: cursorLine
            x: edit.cursorRectangle.x; y: edit.cursorRectangle.y
            width: edit.cursorRectangle.width; height: edit.cursorRectangle.height
        }
        Accessible.role: Accessible.StaticText
        Accessible.name: block.text
        Accessible.focusable: true
    }
    FocusRing { target: edit; cornerRadius: block.radius; outset: 0 }
    QQC2.ToolButton {
        id: copy
        anchors.right: parent.right; anchors.top: parent.top
        anchors.margins: Kirigami.Units.smallSpacing
        icon.name: "edit-copy"
        display: QQC2.AbstractButton.IconOnly
        text: qsTr("Copy")
        QQC2.ToolTip.text: text
        QQC2.ToolTip.visible: hovered
        QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
        Accessible.name: text
        onActiveFocusChanged: if (activeFocus && visualFocus) Util.reveal(block.flickable, this, Kirigami.Units.gridUnit)
        onClicked: { edit.selectAll(); edit.copy(); edit.deselect() }
    }
}
