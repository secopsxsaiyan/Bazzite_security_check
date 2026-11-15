// Security Check - the band at the top of every page: an icon, an optional
// small line above the title, the title and a line under it. Items placed
// inside it go in a row under the subtitle (chips, counts).
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

Rectangle {
    id: header
    property string iconSource: ""       // a file URL
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
            visible: leadingSlot.children.length === 0 && header.iconSource !== ""
            source: header.iconSource
            Layout.alignment: Qt.AlignTop
            implicitWidth: Kirigami.Units.iconSizes.large; implicitHeight: implicitWidth
            // Decoration (the app's icon, or one that repeats the title). A
            // page whose icon says something puts its own item in "leading".
            Accessible.ignored: true
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            QQC2.Label { visible: header.eyebrow !== ""; text: header.eyebrow; opacity: Util.dimLabel; textFormat: Text.PlainText }
            // A title from the PC can be very long: three lines of it, the
            // whole of it in a tool tip (and for a screen reader).
            Kirigami.Heading {
                Layout.fillWidth: true; level: 2; wrapMode: Text.Wrap; textFormat: Text.PlainText
                maximumLineCount: 3; elide: Text.ElideRight
                text: header.title
                Accessible.role: Accessible.Heading
                Accessible.name: header.title
                QQC2.ToolTip.visible: truncated && titleHover.hovered
                QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                QQC2.ToolTip.text: Util.tip(header.title)
                HoverHandler { id: titleHover }
            }
            QQC2.Label {
                visible: header.subtitle !== ""
                Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                opacity: Util.dimText; text: header.subtitle
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
