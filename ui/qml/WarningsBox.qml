// Security Check - "before you apply" side effects of a fix.
// warnings: [{tag, text}]
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.InlineMessage {
    id: box
    property var warnings: []
    function esc(s) { return String(s === undefined ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
    Layout.fillWidth: true
    visible: (warnings || []).length > 0
    type: Kirigami.MessageType.Warning
    text: "<b>" + qsTr("Before you apply") + "</b><br>" + (warnings || []).map(function (w) {
        return "<b>" + box.esc(w.tag) + ":</b> " + box.esc(w.text) }).join("<br>")
}
