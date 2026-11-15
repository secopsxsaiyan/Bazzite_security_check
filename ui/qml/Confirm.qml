// Security Check - confirm one fix (a page of the main window): the setting
// now and after, what it affects on Bazzite, the side effects, the exact
// commands and whether it can be undone. Apply / Skip / Stop reviewing.
// finished({choice: "apply" | "skip" | "stop"}) answers.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

Item {
    id: page
    required property var input
    property string iconSource: ""
    readonly property string title: qsTr("Apply this fix?")
    signal finished(var answer)
    signal cancelled()
    // Enter applies, unless another button has the keyboard focus (the
    // window presses that one: a focused "Skip" never applies the fix).
    function primary() { answer("apply") }
    function dismiss() { cancelled() }
    // No button starts with the keyboard focus. Space presses the focused
    // button, and the fixes come one after the other: with the focus on
    // Apply, the Space meant for "Skip" on the fix before would apply this
    // one. Apply by Space or a click takes a deliberate move to the button.
    function initialFocus() { return null }

    readonly property var d: input || ({})
    function answer(c) { finished({ "choice": c }) }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        PageHeader {
            iconSource: page.iconSource
            eyebrow: qsTr("Apply this fix?")
            title: page.d.title || ""
            StatusChip { sev: page.d.sev || "info" }
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

                ExpandableText { text: page.d.detail || ""; flickable: scroll.contentItem }

                AffectsList { model: page.d.affects || [] }

                WarningsBox { warnings: page.d.warnings || [] }

                Section {
                    title: qsTr("Commands")
                    visible: (page.d.commands || "") !== ""
                    QQC2.Label {
                        Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                        opacity: Util.dimText
                        text: qsTr("These run as administrator. You are not asked for your password again.")
                    }
                    CodeBlock { text: page.d.commands || ""; flickable: scroll.contentItem }
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
            leading: QQC2.Button { text: qsTr("Stop reviewing"); icon.name: "process-stop"; onClicked: page.answer("stop") }
            QQC2.Button { text: qsTr("Skip"); icon.name: "go-next"; onClicked: page.answer("skip") }
            PrimaryButton { text: qsTr("Apply"); icon.name: "dialog-ok-apply"; onClicked: page.primary() }
        }
    }
}
