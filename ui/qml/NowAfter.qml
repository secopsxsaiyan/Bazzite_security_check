// Security Check - a setting now and after the fix, one above the other
// with their labels in a column on the left. The values (and the label of
// the second one) come from the PC: plain text. The value after the fix is
// green as text can be and still be read (Util.ink), and in heavier type:
// the labels say which is which. A long label wraps: the label column is
// ten grid units wide at most.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

GridLayout {
    id: grid
    property string now: ""
    property string after: ""
    // "" is the usual label.
    property string afterLabel: ""
    readonly property real labelWidth: Kirigami.Units.gridUnit * 10
    Layout.fillWidth: true
    visible: now !== "" || after !== ""
    columns: 2
    columnSpacing: Kirigami.Units.largeSpacing
    rowSpacing: Kirigami.Units.smallSpacing
    QQC2.Label {
        visible: grid.now !== ""; text: qsTr("Now"); textFormat: Text.PlainText; opacity: Util.dimLabel
        Layout.alignment: Qt.AlignTop; Layout.maximumWidth: grid.labelWidth; wrapMode: Text.Wrap
    }
    QQC2.Label { visible: grid.now !== ""; Layout.fillWidth: true; Layout.alignment: Qt.AlignTop; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: grid.now }
    QQC2.Label {
        visible: grid.after !== ""; text: grid.afterLabel || qsTr("After the fix"); textFormat: Text.PlainText; opacity: Util.dimLabel
        Layout.alignment: Qt.AlignTop; Layout.maximumWidth: grid.labelWidth; wrapMode: Text.Wrap
    }
    QQC2.Label {
        visible: grid.after !== ""; Layout.fillWidth: true; Layout.alignment: Qt.AlignTop; wrapMode: Text.Wrap; textFormat: Text.PlainText
        text: grid.after; font.weight: Font.DemiBold
        color: Util.ink(Kirigami.Theme, Kirigami.Theme.positiveTextColor)
    }
}
