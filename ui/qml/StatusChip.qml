// Security Check - a small rounded label in one colour (severity, risk,
// state). Set "sev" for a severity or risk, or text and tint yourself.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Rectangle {
    id: chip
    property string sev: ""            // high | medium | low | info
    property string text: sev === "high" ? qsTr("High") : sev === "medium" ? qsTr("Medium") : sev === "low" ? qsTr("Low") : sev === "info" ? qsTr("Info") : ""
    property string iconName: ""
    property color tint: sev === "high" ? Kirigami.Theme.negativeTextColor : sev === "medium" ? Kirigami.Theme.neutralTextColor
                       : sev === "low" ? Kirigami.Theme.linkColor : Kirigami.Theme.disabledTextColor

    radius: height / 2
    implicitHeight: row.implicitHeight + Kirigami.Units.smallSpacing
    implicitWidth: row.implicitWidth + Kirigami.Units.largeSpacing * 2
    color: Qt.rgba(tint.r, tint.g, tint.b, 0.15)
    border.color: Qt.rgba(tint.r, tint.g, tint.b, 0.6)
    Accessible.role: Accessible.StaticText
    Accessible.name: text

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: Kirigami.Units.smallSpacing
        Kirigami.Icon {
            visible: chip.iconName !== ""
            source: chip.iconName
            implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth
        }
        QQC2.Label { text: chip.text; font: Kirigami.Theme.smallFont; color: chip.tint }
    }
}
