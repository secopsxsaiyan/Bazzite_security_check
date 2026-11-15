// Security Check - the bar at the bottom of every page: buttons that leave
// the flow on the left ("leading"), a one-line hint, and the page's buttons
// on the right with the main one (a PrimaryButton) last. "stacked" puts the
// page's buttons one under the other, each as wide as the bar: for a dialog
// whose buttons do not fit next to each other. A hint that has no room
// next to the buttons (a narrow window, large text) goes on a line of its
// own above them.
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
    // The room the hint has between the buttons, and whether two lines of
    // it hold the hint. Worked out from the buttons' own widths and from
    // the hint laid out in that room by a label that is never shown, not
    // from where the hint is now (the two would chase each other).
    readonly property real hintRoom: width - Kirigami.Units.largeSpacing * 3 - buttonRow.implicitWidth
                                     - (leadRow.visible ? leadRow.implicitWidth + Kirigami.Units.largeSpacing : 0)
    readonly property bool hintAbove: !stacked && hint !== "" && (hintRoom < Kirigami.Units.gridUnit * 4 || hintProbe.lineCount > 2)
    QQC2.Label {
        id: hintProbe
        visible: false
        width: Math.max(1, bar.hintRoom - 1)
        wrapMode: Text.Wrap; textFormat: Text.PlainText
        font: hintLabel.font; text: bar.hint
    }

    Kirigami.Separator { Layout.fillWidth: true }
    QQC2.Label {
        visible: bar.hintAbove
        Layout.fillWidth: true
        Layout.margins: Kirigami.Units.largeSpacing
        Layout.bottomMargin: 0
        wrapMode: Text.Wrap; textFormat: Text.PlainText
        maximumLineCount: 3; elide: Text.ElideRight
        opacity: Util.dimText; text: bar.hint
    }
    RowLayout {
        Layout.fillWidth: true
        Layout.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing
        RowLayout { id: leadRow; visible: children.length > 0; spacing: Kirigami.Units.smallSpacing }
        // Also what keeps the buttons on the right when it is empty.
        QQC2.Label {
            id: hintLabel
            visible: !bar.stacked
            Layout.fillWidth: true
            wrapMode: Text.Wrap; textFormat: Text.PlainText
            maximumLineCount: 2; elide: Text.ElideRight
            opacity: Util.dimText; text: bar.hintAbove ? "" : bar.hint
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
