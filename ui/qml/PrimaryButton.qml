// Security Check - the main button of a page: filled with the highlight
// colour so it stands out from the other buttons in every Plasma style.
// Enter presses it from anywhere on the page (Shell.qml: the page's
// primary()), unless another button has the keyboard focus.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

QQC2.Button {
    id: control
    // "destructive: true" fills it with the negative colour instead.
    property bool destructive: false
    readonly property color fill: destructive ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.highlightColor

    font.bold: true
    leftPadding: Kirigami.Units.largeSpacing * 2
    rightPadding: Kirigami.Units.largeSpacing * 2
    topPadding: Kirigami.Units.smallSpacing * 1.5
    bottomPadding: Kirigami.Units.smallSpacing * 1.5
    Accessible.role: Accessible.Button
    Accessible.name: text

    contentItem: RowLayout {
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
            text: control.text
            textFormat: Text.PlainText
            font: control.font
            color: Kirigami.Theme.highlightedTextColor
        }
        Item { Layout.fillWidth: true }
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
