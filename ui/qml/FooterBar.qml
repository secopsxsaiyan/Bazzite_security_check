// Security Check - the bar at the bottom of every page: buttons that leave
// the flow on the left ("leading"), a one-line hint, and the page's buttons
// on the right with the main one (a PrimaryButton) last. "stacked" puts the
// page's buttons one under the other, each as wide as the bar: for a dialog
// whose buttons do not fit next to each other.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

ColumnLayout {
    id: bar
    property string hint: ""
    property bool stacked: false
    property alias leading: leadRow.data
    default property alias buttons: buttonRow.data

    Layout.fillWidth: true
    spacing: 0
    Kirigami.Separator { Layout.fillWidth: true }
    RowLayout {
        Layout.fillWidth: true
        Layout.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing
        RowLayout { id: leadRow; visible: children.length > 0; spacing: Kirigami.Units.smallSpacing }
        QQC2.Label {
            visible: !bar.stacked
            Layout.fillWidth: true
            wrapMode: Text.Wrap; textFormat: Text.PlainText
            maximumLineCount: 2; elide: Text.ElideRight
            opacity: Util.dimText; text: bar.hint
        }
        GridLayout {
            id: buttonRow
            Layout.fillWidth: bar.stacked
            // One row, or one column.
            flow: bar.stacked ? GridLayout.TopToBottom : GridLayout.LeftToRight
            rows: bar.stacked ? -1 : 1
            columns: bar.stacked ? 1 : -1
            rowSpacing: Kirigami.Units.smallSpacing
            columnSpacing: Kirigami.Units.smallSpacing
        }
    }
}
