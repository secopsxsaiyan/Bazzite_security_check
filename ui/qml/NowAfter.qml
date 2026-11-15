// Security Check - a setting now and after the fix, one above the other
// with their labels in a column on the left. The values (and the label of
// the second one) come from the PC: plain text.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

GridLayout {
    id: grid
    property string now: ""
    property string after: ""
    property string afterLabel: qsTr("After the fix")
    Layout.fillWidth: true
    visible: now !== "" || after !== ""
    columns: 2
    columnSpacing: Kirigami.Units.largeSpacing
    rowSpacing: Kirigami.Units.smallSpacing
    QQC2.Label { visible: grid.now !== ""; text: qsTr("Now"); textFormat: Text.PlainText; opacity: 0.75; Layout.alignment: Qt.AlignTop }
    QQC2.Label { visible: grid.now !== ""; Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: grid.now }
    QQC2.Label { visible: grid.after !== ""; text: grid.afterLabel; textFormat: Text.PlainText; opacity: 0.75; Layout.alignment: Qt.AlignTop }
    QQC2.Label {
        visible: grid.after !== ""; Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
        text: grid.after; color: Kirigami.Theme.positiveTextColor
    }
}
