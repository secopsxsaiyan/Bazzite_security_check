// Security Check - "before you apply" side effects of a fix.
// warnings: [{tag, text}]. The box shows rich text, so the tags and texts
// (which may name things found on the PC) are escaped.
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

Kirigami.InlineMessage {
    id: box
    property var warnings: []
    Layout.fillWidth: true
    visible: (warnings || []).length > 0
    type: Kirigami.MessageType.Warning
    text: "<b>" + qsTr("Before you apply") + "</b><br>" + (warnings || []).map(function (w) {
        return "<b>" + qsTr("%1:").arg(Util.esc(w.tag)) + "</b> " + Util.esc(w.text) }).join("<br>")
}
