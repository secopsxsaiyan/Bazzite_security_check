// Security Check - the band at the top of every page: an icon, an optional
// small line above the title, the title and a line under it. Items placed
// inside it go in a row under the subtitle (chips, counts).
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Rectangle {
    id: header
    property string iconName: ""
    property string iconSource: ""       // a file URL, used when iconName is empty
    property string eyebrow: ""
    property string title: ""
    property string subtitle: ""
    // An item shown left of the text instead of the icon (the score ring).
    property alias leading: leadingSlot.data
    default property alias extra: extraRow.data

    Layout.fillWidth: true
    implicitHeight: row.implicitHeight + Kirigami.Units.gridUnit * 1.5
    color: Kirigami.Theme.alternateBackgroundColor
    Kirigami.Theme.colorSet: Kirigami.Theme.Header
    Kirigami.Theme.inherit: false

    RowLayout {
        id: row
        anchors.fill: parent
        anchors.margins: Kirigami.Units.gridUnit
        spacing: Kirigami.Units.gridUnit
        Item {
            id: leadingSlot
            visible: children.length > 0
            implicitWidth: childrenRect.width; implicitHeight: childrenRect.height
            Layout.alignment: Qt.AlignVCenter
        }
        Kirigami.Icon {
            visible: leadingSlot.children.length === 0 && (header.iconName !== "" || header.iconSource !== "")
            source: header.iconName !== "" ? header.iconName : header.iconSource
            Layout.alignment: Qt.AlignTop
            implicitWidth: Kirigami.Units.iconSizes.large; implicitHeight: implicitWidth
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            QQC2.Label { visible: header.eyebrow !== ""; text: header.eyebrow; opacity: 0.75; textFormat: Text.PlainText }
            Kirigami.Heading {
                Layout.fillWidth: true; level: 2; wrapMode: Text.Wrap; textFormat: Text.PlainText
                text: header.title
                Accessible.role: Accessible.Heading
            }
            QQC2.Label {
                visible: header.subtitle !== ""
                Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                opacity: 0.8; text: header.subtitle
            }
            RowLayout {
                id: extraRow
                visible: children.length > 0
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
            }
        }
    }
    Kirigami.Separator { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom }
}
