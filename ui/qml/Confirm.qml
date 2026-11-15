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
    // This is the one page where Enter is not the main button from
    // anywhere: a fix is applied only by a click on Apply, by its Alt key,
    // or by Enter or Space while Apply itself has the keyboard focus. (The
    // window presses a focused button on Enter, so a focused "Skip" skips;
    // with the focus anywhere else Enter comes here and does nothing.) A
    // fix may be a risky one, and an Enter too many on the page before
    // must never run it.
    function primary() { if (applyButton.activeFocus) answer("apply") }
    function dismiss() { cancelled() }
    // No button starts with the keyboard focus either. Space presses the
    // focused button, and the fixes come one after the other: with the
    // focus on Apply, the Space meant for "Skip" on the fix before would
    // apply this one. Applying takes a deliberate move to the button: Tab
    // goes through the page to it, Shift+Tab goes straight to it (it is
    // the last control).
    function initialFocus() { return null }
    readonly property Item scrollArea: scroll.contentItem

    readonly property var d: input || ({})
    function answer(c) { finished({ "choice": c }) }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        PageHeader {
            iconSource: page.iconSource
            // Without a title the question is the title.
            eyebrow: page.d.title ? qsTr("Apply this fix?") : ""
            title: page.d.title || qsTr("Apply this fix?")
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

                Notice {
                    kind: page.d.undo === true ? "positive" : "error"
                    title: page.d.undo === true ? qsTr("Can be undone") : qsTr("No automatic undo.")
                    text: page.d.undo === true ? qsTr("later: “Undo changes…” on the Check-up result page, or run the tool with --undo.") : ""
                }

                QQC2.Label {
                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    visible: text !== ""; font.italic: true; text: page.d.note || ""
                }

                Item { implicitHeight: Kirigami.Units.smallSpacing }
            }
        }

        FooterBar {
            // Enter alone does not apply (see primary()): say what does.
            hint: qsTr("Nothing changes until you press Apply. With the keyboard: Tab to Apply, then Enter.")
            leading: QQC2.Button { text: qsTr("Stop reviewing"); icon.name: "process-stop"; onClicked: page.answer("stop") }
            QQC2.Button { text: qsTr("Skip"); icon.name: "go-next"; onClicked: page.answer("skip") }
            PrimaryButton {
                id: applyButton
                text: qsTr("Apply"); icon.name: "dialog-ok-apply"
                Accessible.description: qsTr("Runs the commands shown on this page")
                onClicked: page.answer("apply")
            }
        }
    }
}
