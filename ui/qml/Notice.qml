// Security Check - a message in a tinted box: an icon, a few words in bold
// and a sentence. Like Kirigami.InlineMessage to look at, but its text is
// plain text here (title and text may come from the PC and are escaped),
// and a screen reader gets it as plain text too: InlineMessage hands
// assistive tools the markup of its rich text.
// Lines placed inside it go under the text, in a column.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

Rectangle {
    id: box
    property string kind: "info"       // info | positive | warning | error
    property string title: ""          // shown in bold, in front of the text
    property string text: ""
    default property alias lines: more.data
    // What a screen reader says: the title and the text, plus what the
    // lines inside it add (WarningsBox).
    property string spoken: [title, text].filter(function (s) { return s !== "" }).join(" ")

    readonly property color tint: kind === "positive" ? Kirigami.Theme.positiveTextColor
                                : kind === "warning" ? Kirigami.Theme.neutralTextColor
                                : kind === "error" ? Kirigami.Theme.negativeTextColor
                                : Kirigami.Theme.activeTextColor
    // The share of the tint in the fill, as Kirigami.InlineMessage has it.
    readonly property real fillStrength: 0.2

    Layout.fillWidth: true
    implicitHeight: row.implicitHeight + Kirigami.Units.largeSpacing * 2
    implicitWidth: row.implicitWidth + Kirigami.Units.largeSpacing * 2
    radius: Kirigami.Units.cornerRadius
    color: Kirigami.ColorUtils.tintWithAlpha(Kirigami.Theme.backgroundColor, tint, fillStrength)
    border.width: 1
    border.color: tint
    Accessible.role: Accessible.AlertMessage
    Accessible.name: spoken
    Accessible.ignored: !visible

    RowLayout {
        id: row
        anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing
        // The kind is in the icon too, not in the colour alone.
        Kirigami.Icon {
            source: box.kind === "positive" ? "data-success" : box.kind === "warning" ? "data-warning"
                  : box.kind === "error" ? "data-error" : "data-information"
            fallback: box.kind === "positive" ? "dialog-ok-apply" : box.kind === "warning" ? "dialog-warning"
                    : box.kind === "error" ? "dialog-error" : "dialog-information"
            implicitWidth: Kirigami.Units.iconSizes.smallMedium; implicitHeight: implicitWidth
            Layout.alignment: more.children.length > 0 || label.lineCount > 1 ? Qt.AlignTop : Qt.AlignVCenter
            Accessible.ignored: true
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            QQC2.Label {
                id: label
                Layout.fillWidth: true
                visible: text !== ""
                wrapMode: Text.Wrap
                textFormat: Text.StyledText
                text: (box.title !== "" ? "<b>" + Util.esc(box.title) + "</b>" : "")
                    + (box.title !== "" && box.text !== "" ? " " : "") + Util.esc(box.text)
                color: Kirigami.Theme.textColor
                Accessible.ignored: true    // the box says it, as plain text
            }
            ColumnLayout {
                id: more
                Layout.fillWidth: true
                visible: children.length > 0
                spacing: Kirigami.Units.smallSpacing
            }
        }
    }
}
