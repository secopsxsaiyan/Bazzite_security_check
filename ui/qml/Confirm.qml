// Security Check - confirm one fix (Kirigami), in the wizard's style: the
// setting now and after, what it affects on Bazzite, the side effects, the
// exact commands and whether it can be undone. Apply / Skip / Stop.
// bridge.finish({choice: "apply" | "skip" | "stop"}) answers.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.ApplicationWindow {
    id: root
    title: "Security Check"
    width: Kirigami.Units.gridUnit * 48
    height: Kirigami.Units.gridUnit * 40
    minimumWidth: Kirigami.Units.gridUnit * 32
    minimumHeight: Kirigami.Units.gridUnit * 26
    pageStack.globalToolBar.style: Kirigami.ApplicationHeaderStyle.None

    readonly property var d: bridge.input
    property bool more: false
    function esc(s) { return String(s === undefined ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
    function sevColor(s) {
        return s === "high" ? Kirigami.Theme.negativeTextColor : s === "medium" ? Kirigami.Theme.neutralTextColor
             : s === "low" ? Kirigami.Theme.linkColor : Kirigami.Theme.disabledTextColor
    }
    function answer(c) { bridge.finish({ "choice": c }) }

    onClosing: bridge.cancel()

    pageStack.initialPage: Kirigami.Page {
        padding: 0
        titleDelegate: Item {}

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: head.implicitHeight + Kirigami.Units.gridUnit * 1.5
                color: Kirigami.Theme.alternateBackgroundColor
                Kirigami.Theme.colorSet: Kirigami.Theme.Header
                Kirigami.Theme.inherit: false
                RowLayout {
                    id: head
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.gridUnit
                    spacing: Kirigami.Units.gridUnit
                    Kirigami.Icon {
                        source: "tools-wizard"
                        Layout.alignment: Qt.AlignTop
                        implicitWidth: Kirigami.Units.iconSizes.large; implicitHeight: implicitWidth
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        QQC2.Label { text: "Apply this fix?"; opacity: 0.75 }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing
                            Rectangle {
                                radius: height / 2
                                implicitHeight: sev.implicitHeight + Kirigami.Units.smallSpacing
                                implicitWidth: sev.implicitWidth + Kirigami.Units.largeSpacing * 2
                                color: Qt.rgba(root.sevColor(root.d.sev).r, root.sevColor(root.d.sev).g, root.sevColor(root.d.sev).b, 0.15)
                                border.color: root.sevColor(root.d.sev)
                                QQC2.Label { id: sev; anchors.centerIn: parent; text: (root.d.sev || "info").toUpperCase(); font: Kirigami.Theme.smallFont; color: root.sevColor(root.d.sev) }
                            }
                            Kirigami.Heading { Layout.fillWidth: true; level: 2; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: root.d.title || "" }
                        }
                    }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: availableWidth
                clip: true

                ColumnLayout {
                    width: parent.width - Kirigami.Units.gridUnit * 2
                    x: Kirigami.Units.gridUnit
                    spacing: Kirigami.Units.largeSpacing

                    Item { implicitHeight: Kirigami.Units.smallSpacing }
                    GridLayout {
                        Layout.fillWidth: true
                        visible: !!(root.d.now || root.d.after)
                        columns: 2
                        columnSpacing: Kirigami.Units.largeSpacing
                        QQC2.Label { visible: !!root.d.now; text: "Now"; font.bold: true; Layout.alignment: Qt.AlignTop }
                        QQC2.Label { visible: !!root.d.now; Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: root.d.now || "" }
                        QQC2.Label { visible: !!root.d.after; text: "After"; font.bold: true; Layout.alignment: Qt.AlignTop }
                        QQC2.Label { visible: !!root.d.after; Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: root.d.after || ""; color: Kirigami.Theme.positiveTextColor }
                    }

                    QQC2.Label {
                        Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                        text: root.d.detail || ""
                        maximumLineCount: root.more ? 100000 : 6
                        elide: Text.ElideRight
                    }
                    QQC2.Button {
                        visible: (root.d.detail || "").split("\n").length > 6 || (root.d.detail || "").length > 600
                        flat: true
                        text: root.more ? "Show less" : "Show all details"
                        icon.name: root.more ? "go-up" : "go-down"
                        onClicked: root.more = !root.more
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: (root.d.affects || []).length > 0
                        spacing: Kirigami.Units.smallSpacing
                        QQC2.Label { text: "What this affects on Bazzite"; font.bold: true }
                        Repeater {
                            model: root.d.affects || []
                            delegate: ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                QQC2.Label {
                                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                                    font.weight: Font.DemiBold
                                    color: modelData.stops && modelData.status === "in" ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                                    text: modelData.name + " - " + modelData.how + " (" + modelData.where + ")"
                                }
                                QQC2.Label { Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText; opacity: 0.85; text: modelData.sentence }
                            }
                        }
                    }

                    Kirigami.InlineMessage {
                        Layout.fillWidth: true
                        visible: (root.d.warnings || []).length > 0
                        type: Kirigami.MessageType.Warning
                        text: "<b>Before you apply:</b><br>" + (root.d.warnings || []).map(function (w) {
                            return "<b>" + root.esc(w.tag) + "</b> - " + root.esc(w.text) }).join("<br>")
                    }

                    QQC2.Label {
                        text: "Commands (run as administrator; you are not asked for your password again)"
                        font.bold: true
                    }
                    QQC2.TextArea {
                        Layout.fillWidth: true
                        readOnly: true
                        wrapMode: TextEdit.Wrap
                        textFormat: TextEdit.PlainText
                        font.family: "monospace"
                        text: root.d.commands || ""
                    }

                    Kirigami.InlineMessage {
                        Layout.fillWidth: true
                        visible: true
                        type: root.d.undo === true ? Kirigami.MessageType.Positive : Kirigami.MessageType.Error
                        text: root.d.undo === true ? "<b>Can be undone</b> later: dashboard → Undo, or run the tool with --undo."
                                                   : "<b>No automatic undo.</b>"
                    }
                    QQC2.Label {
                        Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                        visible: !!root.d.note; font.italic: true; text: root.d.note || ""
                    }
                    Item { implicitHeight: Kirigami.Units.smallSpacing }
                }
            }

            Kirigami.Separator { Layout.fillWidth: true }
            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                QQC2.Button { text: "Stop reviewing"; icon.name: "process-stop"; onClicked: root.answer("stop") }
                Item { Layout.fillWidth: true }
                QQC2.Button { text: "Skip"; icon.name: "go-next"; onClicked: root.answer("skip") }
                QQC2.Button { text: "Apply"; icon.name: "dialog-ok-apply"; highlighted: true; font.bold: true; onClicked: root.answer("apply") }
            }
        }
    }
}
