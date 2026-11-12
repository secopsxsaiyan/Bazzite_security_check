// Security Check - one check's page (Kirigami), in the wizard's style: what
// the check saw and each finding as a card, with what the fix changes, what
// it affects on Bazzite, its side effects and the manual steps. Every
// finding that can be fixed has its own tick box, plus Select all.
// bridge.finish({action: "fix", ids: [...]}) or {action: "back"} answers;
// the root side keeps only ids it offered.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.ApplicationWindow {
    id: root
    title: "Security Check"
    width: Kirigami.Units.gridUnit * 50
    height: Kirigami.Units.gridUnit * 42
    minimumWidth: Kirigami.Units.gridUnit * 32
    minimumHeight: Kirigami.Units.gridUnit * 26
    pageStack.globalToolBar.style: Kirigami.ApplicationHeaderStyle.None

    readonly property var d: bridge.input
    readonly property var findings: d.findings || []
    readonly property var fixable: findings.filter(function (f) { return f.fixable === true })
    property var picked: ({})
    readonly property int count: fixable.filter(function (f) { return picked[f.id] === true }).length

    Component.onCompleted: {
        var p = {}
        fixable.forEach(function (f) { p[f.id] = f.on === true })
        picked = p
    }
    function toggle(id, v) { var p = Object.assign({}, picked); p[id] = v; picked = p }
    function setAll(v) { var p = {}; fixable.forEach(function (f) { p[f.id] = v }); picked = p }
    function fix() {
        bridge.finish({ "action": "fix", "ids": fixable.filter(function (f) { return picked[f.id] === true }).map(function (f) { return f.id }) })
    }

    function sevColor(s) {
        return s === "high" ? Kirigami.Theme.negativeTextColor : s === "medium" ? Kirigami.Theme.neutralTextColor
             : s === "low" ? Kirigami.Theme.linkColor : Kirigami.Theme.disabledTextColor
    }
    function stateIcon(s) {
        return s === "bad" ? "dialog-error" : s === "warn" ? "dialog-information"
             : s === "reboot" ? "system-reboot" : (s === "ok" || s === "fixed") ? "dialog-ok-apply"
             : s === "note" ? "dialog-information" : s === "error" ? "dialog-error" : "dialog-cancel"
    }
    function markColor(a) {
        return a.stops && a.status === "in" ? Kirigami.Theme.negativeTextColor
             : a.mark === "+" ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.textColor
    }

    // Descriptions are wrapped at about 78 columns in the checks: join
    // those lines again (list lines and blank lines stay).
    function reflow(s) {
        var out = [], lines = String(s === undefined ? "" : s).split("\n")
        for (var n = 0; n < lines.length; n++) {
            var l = lines[n], prev = out.length ? out[out.length - 1] : ""
            if (out.length && l.trim() !== "" && prev.trim() !== "" && !/^\s*[-•*]\s/.test(l) && !/^\s*[-•*]\s/.test(prev))
                out[out.length - 1] = prev + " " + l.trim()
            else
                out.push(l)
        }
        return out.join("\n")
    }

    onClosing: bridge.cancel()

    pageStack.initialPage: Kirigami.Page {
        padding: 0
        titleDelegate: Item {}

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // ---- header -------------------------------------------------
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
                        source: root.stateIcon(root.d.state || "")
                        Layout.alignment: Qt.AlignTop
                        implicitWidth: Kirigami.Units.iconSizes.large; implicitHeight: implicitWidth
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Heading { text: root.d.title || ""; level: 1; textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        QQC2.Label {
                            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText; opacity: 0.8
                            text: (root.d.area || "") + (root.d.summary ? " · " + root.d.summary : "")
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
                    width: parent.width
                    spacing: Kirigami.Units.largeSpacing

                    // ---- what the check saw ---------------------------------
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: Kirigami.Units.largeSpacing
                        Layout.leftMargin: Kirigami.Units.gridUnit; Layout.rightMargin: Kirigami.Units.gridUnit
                        visible: (root.d.notes || []).length > 0
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Heading { level: 3; text: "What the check saw" }
                        Repeater {
                            model: root.d.notes || []
                            delegate: RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing
                                QQC2.Label { text: "•"; Layout.alignment: Qt.AlignTop }
                                QQC2.Label { Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: modelData }
                            }
                        }
                    }

                    QQC2.Label {
                        Layout.leftMargin: Kirigami.Units.gridUnit
                        visible: root.findings.length === 0
                        text: "Nothing to report."
                    }

                    // ---- select all ------------------------------------------
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.gridUnit; Layout.rightMargin: Kirigami.Units.gridUnit
                        visible: root.fixable.length > 1
                        QQC2.CheckBox {
                            text: "Select all " + root.fixable.length + " that can be fixed here"
                            checked: root.count === root.fixable.length
                            onToggled: root.setAll(checked)
                        }
                    }

                    // ---- findings ---------------------------------------------
                    Repeater {
                        model: root.findings
                        delegate: Rectangle {
                            id: card
                            required property var modelData
                            readonly property var f: modelData
                            readonly property bool on: root.picked[f.id] === true
                            property bool more: false
                            property bool manualOpen: false
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit; Layout.rightMargin: Kirigami.Units.gridUnit
                            implicitHeight: cardBody.implicitHeight + Kirigami.Units.gridUnit
                            radius: Kirigami.Units.cornerRadius
                            color: Kirigami.Theme.backgroundColor
                            border.color: on ? Kirigami.Theme.highlightColor
                                             : Qt.rgba(root.sevColor(f.sev).r, root.sevColor(f.sev).g, root.sevColor(f.sev).b, 0.45)
                            border.width: on ? 2 : 1

                            ColumnLayout {
                                id: cardBody
                                anchors.fill: parent
                                anchors.margins: Kirigami.Units.gridUnit * 0.5
                                spacing: Kirigami.Units.smallSpacing

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing
                                    QQC2.CheckBox {
                                        visible: card.f.fixable === true
                                        checked: card.on
                                        onToggled: root.toggle(card.f.id, checked)
                                        Accessible.name: "Fix: " + card.f.title
                                    }
                                    Rectangle {
                                        radius: height / 2
                                        implicitHeight: sevLabel.implicitHeight + Kirigami.Units.smallSpacing
                                        implicitWidth: sevLabel.implicitWidth + Kirigami.Units.largeSpacing * 2
                                        color: Qt.rgba(root.sevColor(card.f.sev).r, root.sevColor(card.f.sev).g, root.sevColor(card.f.sev).b, 0.15)
                                        border.color: root.sevColor(card.f.sev)
                                        QQC2.Label {
                                            id: sevLabel
                                            anchors.centerIn: parent
                                            text: (card.f.sev || "info").toUpperCase() + " SEVERITY"
                                            font: Kirigami.Theme.smallFont
                                            color: root.sevColor(card.f.sev)
                                        }
                                    }
                                    QQC2.Label {
                                        Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                                        font.weight: Font.DemiBold; text: card.f.title
                                    }
                                }
                                QQC2.Label {
                                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                                    font.italic: true; opacity: 0.75; text: card.f.status || ""
                                }

                                // Now / after
                                GridLayout {
                                    Layout.fillWidth: true
                                    visible: !!(card.f.now || card.f.after)
                                    columns: 2
                                    columnSpacing: Kirigami.Units.largeSpacing
                                    rowSpacing: Kirigami.Units.smallSpacing
                                    QQC2.Label { visible: !!card.f.now; text: "Now"; font.bold: true; Layout.alignment: Qt.AlignTop }
                                    QQC2.Label { visible: !!card.f.now; Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: card.f.now || "" }
                                    QQC2.Label { visible: !!card.f.after; text: card.f.after_label || "After"; font.bold: true; Layout.alignment: Qt.AlignTop }
                                    QQC2.Label { visible: !!card.f.after; Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: card.f.after || ""; color: Kirigami.Theme.positiveTextColor }
                                }

                                // Detail: the first lines, the rest on request.
                                QQC2.Label {
                                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                                    text: root.reflow(card.f.detail)
                                    maximumLineCount: card.more ? 100000 : 6
                                    elide: Text.ElideRight
                                }
                                QQC2.Button {
                                    visible: (card.f.detail || "").split("\n").length > 6 || (card.f.detail || "").length > 600
                                    flat: true
                                    text: card.more ? "Show less" : "Show all details"
                                    icon.name: card.more ? "go-up" : "go-down"
                                    onClicked: card.more = !card.more
                                }

                                // What this affects on Bazzite
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: (card.f.affects || []).length > 0
                                    spacing: Kirigami.Units.smallSpacing
                                    QQC2.Label { text: "What this affects on Bazzite"; font.bold: true }
                                    Repeater {
                                        model: card.f.affects || []
                                        delegate: RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Kirigami.Units.smallSpacing
                                            Kirigami.Icon {
                                                Layout.alignment: Qt.AlignTop
                                                source: modelData.stops && modelData.status === "in" ? "dialog-warning"
                                                      : modelData.mark === "+" ? "dialog-ok-apply" : "dialog-information"
                                                implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth
                                            }
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 0
                                                QQC2.Label {
                                                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                                                    text: modelData.name + " - " + modelData.how + " (" + modelData.where + ")"
                                                    font.weight: Font.DemiBold
                                                    color: root.markColor(modelData)
                                                }
                                                QQC2.Label { Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText; opacity: 0.85; text: modelData.sentence }
                                            }
                                        }
                                    }
                                }

                                // Before you apply
                                Kirigami.InlineMessage {
                                    Layout.fillWidth: true
                                    visible: (card.f.warnings || []).length > 0
                                    type: Kirigami.MessageType.Warning
                                    text: "<b>Before you apply:</b><br>" + (card.f.warnings || []).map(function (w) {
                                        return "<b>" + root.esc(w.tag) + "</b> - " + root.esc(w.text) }).join("<br>")
                                }

                                // How to fix it yourself
                                QQC2.Button {
                                    visible: !!card.f.manual
                                    flat: true
                                    text: card.manualOpen ? "Hide the manual steps" : "How to fix it yourself"
                                    icon.name: "utilities-terminal"
                                    onClicked: card.manualOpen = !card.manualOpen
                                }
                                QQC2.TextArea {
                                    Layout.fillWidth: true
                                    visible: card.manualOpen
                                    readOnly: true
                                    wrapMode: TextEdit.Wrap
                                    textFormat: TextEdit.PlainText
                                    font: Kirigami.Theme.fixedWidthFont
                                    text: card.f.manual || ""
                                }
                            }
                        }
                    }
                    Item { implicitHeight: Kirigami.Units.largeSpacing }
                }
            }

            Kirigami.Separator { Layout.fillWidth: true }
            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                QQC2.Label {
                    Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.75
                    visible: root.fixable.length > 0
                    text: "Each selected fix is shown again with its exact commands, and runs only when you press Apply."
                }
                Item { Layout.fillWidth: true; visible: root.fixable.length === 0 }
                QQC2.Button { text: "Back"; icon.name: "go-previous"; onClicked: bridge.finish({ "action": "back" }) }
                QQC2.Button {
                    visible: root.fixable.length > 0
                    text: "Fix selected (" + root.count + ")"
                    icon.name: "tools-wizard"; highlighted: true; font.bold: true
                    enabled: root.count > 0
                    onClicked: root.fix()
                }
            }
        }
    }

    function esc(s) { return String(s === undefined ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
}
