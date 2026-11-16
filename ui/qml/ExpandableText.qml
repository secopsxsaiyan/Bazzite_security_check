// Security Check - a description from a check: its first lines, and a
// button for the rest when it does not fit in them. The text is plain text
// from the PC, wrapped at about 78 columns there and joined again here.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

ColumnLayout {
    id: box
    property string text: ""
    // How many lines show before "Show all details" is used.
    property int collapsedLines: 6
    property bool expanded: false
    // The scrolling area it is in, if any: the button comes into view when
    // it gets the keyboard focus.
    property Flickable flickable: null

    Layout.fillWidth: true
    visible: label.text !== ""
    spacing: 0

    QQC2.Label {
        id: label
        Layout.fillWidth: true
        wrapMode: Text.Wrap; textFormat: Text.PlainText
        text: Util.reflow(box.text)
        // undefined: back to the default, no limit.
        maximumLineCount: box.expanded ? undefined : box.collapsedLines
        elide: Text.ElideRight
    }
    // There only when lines are cut off at this width (or to fold them
    // again), whatever the length of the text.
    QQC2.Button {
        visible: label.truncated || box.expanded
        // No Alt key: this button is there on one page and not on the
        // next, and would take a letter from a button that is always
        // there (and, until the page has its size, it is there for a
        // moment under a text that fits).
        Kirigami.MnemonicData.enabled: false
        flat: true
        // Its icon lines up with the text above: the style keeps
        // about this much room left of the icon of a flat button
        // (and says so nowhere: its leftPadding is 0).
        Layout.leftMargin: -Kirigami.Units.smallSpacing * 1.5
        text: box.expanded ? qsTr("Show less") : qsTr("Show all details")
        icon.name: box.expanded ? "go-up" : "go-down"
        onClicked: box.expanded = !box.expanded
        onActiveFocusChanged: if (activeFocus && visualFocus) Util.reveal(box.flickable, this, Kirigami.Units.gridUnit)
    }
}
