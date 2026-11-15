// Security Check - a small rounded label in one colour. Set "sev" for the
// severity of a finding or "risk" for the risk of changing an item (text and
// colour follow), or set text and tint yourself.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

Rectangle {
    id: chip
    property string sev: ""            // high | medium | low | info
    property string risk: ""           // high | medium | low
    property string text: sev !== "" ? Util.sevName(sev) : Util.riskText(risk)
    property string iconName: ""
    property color tint: sev !== "" ? Util.sevColor(Kirigami.Theme, sev) : Util.riskColor(Kirigami.Theme, risk)
    // How strong the fill and the outline are, as a share of the tint.
    readonly property real fillStrength: 0.15
    readonly property real edgeStrength: 0.6

    radius: height / 2
    implicitHeight: row.implicitHeight + Kirigami.Units.smallSpacing
    implicitWidth: row.implicitWidth + Kirigami.Units.largeSpacing * 2
    color: Qt.alpha(tint, fillStrength)
    border.color: Qt.alpha(tint, edgeStrength)
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
            Accessible.ignored: true
        }
        // The text may come from the PC: never markup.
        QQC2.Label {
            text: chip.text; textFormat: Text.PlainText
            font: Kirigami.Theme.smallFont; color: chip.tint
            Accessible.ignored: true
        }
    }
}
