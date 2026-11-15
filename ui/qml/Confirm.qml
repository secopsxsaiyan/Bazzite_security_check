// Security Check - confirm one fix (a page of the main window): the setting
// now and after, what it affects on Bazzite, the side effects, the exact
// commands and whether it can be undone. Apply / Skip / Stop reviewing.
// finished({choice: "apply" | "skip" | "stop"}) answers.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Item {
    id: page
    required property var input
    property string iconSource: ""
    readonly property string title: qsTr("Apply this fix?")
    signal finished(var answer)
    signal cancelled()
    function primary() { answer("apply") }
    function dismiss() { cancelled() }

    readonly property var d: input || ({})
    readonly property string detail: reflow(d.detail)
    property bool more: false
    function answer(c) { finished({ "choice": c }) }

    // Descriptions are wrapped at about 78 columns in the checks: join
    // those lines again (list lines and blank lines stay).
    function reflow(s) {
        var out = [], lines = String(s === undefined || s === null ? "" : s).split("\n")
        for (var n = 0; n < lines.length; n++) {
            var l = lines[n], prev = out.length ? out[out.length - 1] : ""
            if (out.length && l.trim() !== "" && prev.trim() !== "" && !/^\s*[-•*]\s/.test(l) && !/^\s*[-•*]\s/.test(prev))
                out[out.length - 1] = prev + " " + l.trim()
            else
                out.push(l)
        }
        return out.join("\n")
    }

    // A button that is not the main one: when it has the keyboard focus,
    // Enter presses it instead of the page's main button (a focused "Skip"
    // must never apply the fix).
    component PlainButton: QQC2.Button {
        Keys.onShortcutOverride: function (event) { event.accepted = event.key === Qt.Key_Return || event.key === Qt.Key_Enter }
        Keys.onReturnPressed: clicked()
        Keys.onEnterPressed: clicked()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        PageHeader {
            iconSource: page.iconSource
            eyebrow: qsTr("Apply this fix?")
            title: page.d.title || ""
            StatusChip {
                sev: page.d.sev || "info"
                text: sev === "high" ? qsTr("High severity") : sev === "medium" ? qsTr("Medium severity")
                    : sev === "low" ? qsTr("Low severity") : qsTr("Information")
            }
        }

        QQC2.ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                // Left-aligned, and no wider than is comfortable to read.
                x: Kirigami.Units.gridUnit
                width: Math.min(scroll.availableWidth - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 48)
                spacing: Kirigami.Units.largeSpacing

                Item { implicitHeight: Kirigami.Units.smallSpacing }

                NowAfter { now: page.d.now || ""; after: page.d.after || "" }

                QQC2.Label {
                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    visible: text !== ""
                    text: page.detail
                    maximumLineCount: page.more ? 100000 : 6
                    elide: Text.ElideRight
                }
                PlainButton {
                    visible: page.detail.split("\n").length > 6 || page.detail.length > 600
                    flat: true
                    text: page.more ? qsTr("Show less") : qsTr("Show all details")
                    icon.name: page.more ? "go-up" : "go-down"
                    onClicked: page.more = !page.more
                }

                AffectsList { model: page.d.affects || [] }

                WarningsBox { warnings: page.d.warnings || [] }

                Section {
                    title: qsTr("Commands")
                    visible: (page.d.commands || "") !== ""
                    QQC2.Label {
                        Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                        opacity: 0.8
                        text: qsTr("These run as administrator. You are not asked for your password again.")
                    }
                    CodeBlock { text: page.d.commands || "" }
                }

                Kirigami.InlineMessage {
                    Layout.fillWidth: true
                    visible: true
                    type: page.d.undo === true ? Kirigami.MessageType.Positive : Kirigami.MessageType.Error
                    text: page.d.undo === true ? qsTr("<b>Can be undone</b> later: dashboard → Undo, or run the tool with --undo.")
                                               : qsTr("<b>No automatic undo.</b>")
                }

                QQC2.Label {
                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    visible: text !== ""; font.italic: true; text: page.d.note || ""
                }

                Item { implicitHeight: Kirigami.Units.smallSpacing }
            }
        }

        FooterBar {
            hint: qsTr("Nothing changes until you press Apply.")
            leading: PlainButton { text: qsTr("Stop reviewing"); icon.name: "process-stop"; onClicked: page.answer("stop") }
            PlainButton { text: qsTr("Skip"); icon.name: "go-next"; onClicked: page.answer("skip") }
            PrimaryButton { text: qsTr("Apply"); icon.name: "dialog-ok-apply"; onClicked: page.primary() }
        }
    }
}
