// Security Check - the main button of a page: filled with the highlight
// colour (a deeper shade of it, so that the label can be read: Util.deep)
// so it stands out from the other buttons in every Plasma style.
// Enter presses it from anywhere on the page (Shell.qml: the page's
// primary()), unless another button has the keyboard focus. Confirm.qml is
// the exception: there, Enter needs the focus on this button.
// With Alt held down its Alt+letter key is underlined, as on every other
// button.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

QQC2.Button {
    id: control
    // "destructive: true" fills it with the negative colour instead.
    property bool destructive: false
    readonly property color fill: Util.deep(Kirigami.Theme, destructive ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.highlightColor)
    // Alt is held down: the letter that presses this button is shown.
    readonly property bool showsKey: Kirigami.MnemonicData.active && Kirigami.MnemonicData.sequence.toString() !== ""

    font.bold: true
    leftPadding: Kirigami.Units.largeSpacing * 2
    rightPadding: Kirigami.Units.largeSpacing * 2
    topPadding: Kirigami.Units.smallSpacing * 1.5
    bottomPadding: Kirigami.Units.smallSpacing * 1.5
    Accessible.role: Accessible.Button
    Accessible.name: text

    // Icon and label as one group in the middle, also when the button is
    // wider than they are ("OK").
    contentItem: Item {
        implicitWidth: group.implicitWidth
        implicitHeight: group.implicitHeight
        RowLayout {
            id: group
            anchors.centerIn: parent
            width: Math.min(implicitWidth, parent.width)
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                visible: control.icon.name !== ""
                source: control.icon.name
                isMask: true
                color: Kirigami.Theme.highlightedTextColor
                implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth
                Accessible.ignored: true
            }
            QQC2.Label {
                Layout.fillWidth: true
                elide: Text.ElideRight
                // The label may hold text from the PC: plain text, and
                // escaped where the underline needs styled text.
                text: control.showsKey ? Util.mnemonic(control.Kirigami.MnemonicData.mnemonicLabel) : control.text
                textFormat: control.showsKey ? Text.StyledText : Text.PlainText
                font: control.font
                color: Kirigami.Theme.highlightedTextColor
                Accessible.ignored: true    // the button says it
            }
        }
    }
    background: Rectangle {
        implicitWidth: Kirigami.Units.gridUnit * 5
        implicitHeight: Kirigami.Units.gridUnit * 1.8
        radius: Kirigami.Units.cornerRadius
        color: !control.enabled ? Kirigami.Theme.disabledTextColor
             : control.down ? Qt.darker(control.fill, 1.25)
             : control.hovered ? Qt.lighter(control.fill, 1.12) : control.fill
        opacity: control.enabled ? 1 : 0.5
        FocusRing { target: control; cornerRadius: parent.radius }
    }
}
