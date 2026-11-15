// Security Check - "before you apply" side effects of a fix.
// warnings: [{tag, text}]. The tags and texts may name things found on the
// PC: they are escaped where a line shows them in bold and plain.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

Notice {
    id: box
    property var warnings: []
    visible: (warnings || []).length > 0
    kind: "warning"
    title: qsTr("Before you apply")
    spoken: title + ". " + (warnings || []).map(function (w) {
        return Util.fill(qsTr("%1: %2"), [w.tag, w.text]) }).join(" ")
    Repeater {
        model: box.warnings || []
        delegate: QQC2.Label {
            required property var modelData
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            textFormat: Text.StyledText
            text: "<b>" + Util.esc(qsTr("%1:").arg(modelData.tag)) + "</b> " + Util.esc(modelData.text)
            Accessible.ignored: true    // the box says it, as plain text
        }
    }
}
