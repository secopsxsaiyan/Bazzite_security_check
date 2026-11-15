// Security Check - what a fix affects on Bazzite: one row per feature with
// an icon for how it is touched, whether this PC uses it, and a sentence.
// model: [{name, how, where, status, mark, stops, sentence}]
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

Section {
    id: list
    property var model: []
    title: qsTr("What this affects on Bazzite")
    visible: (model || []).length > 0
    Repeater {
        model: list.model || []
        delegate: RowLayout {
            id: row
            required property var modelData
            readonly property bool inUse: modelData.stops === true && modelData.status === "in"
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            Accessible.role: Accessible.ListItem
            Accessible.name: Util.fill(qsTr("%1: %2 (%3). %4"), [modelData.name, modelData.how, modelData.where, modelData.sentence])
            Kirigami.Icon {
                source: row.inUse ? "dialog-warning" : row.modelData.mark === "+" ? "dialog-ok-apply" : "dialog-information"
                implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: Kirigami.Units.smallSpacing / 2
                Accessible.ignored: true    // the row's name says it
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    // Both come from the PC and may be long: the name wraps
                    // and the chip is cut, so neither sets the width of the
                    // page.
                    QQC2.Label {
                        Layout.fillWidth: true
                        Layout.maximumWidth: Math.ceil(implicitWidth)
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText; font.weight: Font.DemiBold
                        text: row.modelData.name
                    }
                    StatusChip {
                        Layout.alignment: Qt.AlignTop
                        Layout.maximumWidth: Kirigami.Units.gridUnit * 12
                        text: row.modelData.how
                        tint: row.inUse ? Kirigami.Theme.negativeTextColor
                            : row.modelData.mark === "+" ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor
                    }
                    Item { Layout.fillWidth: true }
                }
                QQC2.Label {
                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    opacity: Util.dimLabel; text: row.modelData.where
                }
                QQC2.Label {
                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    opacity: Util.dimSentence; text: row.modelData.sentence
                }
            }
        }
    }
}
