// Security Check - the dashboard after the checks (Kirigami), in the
// wizard's style. bridge.finish({action, check}) answers; the root side
// validates the action and the check id.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.ApplicationWindow {
    id: root
    title: "Security Check"
    width: Kirigami.Units.gridUnit * 50
    height: Kirigami.Units.gridUnit * 40
    minimumWidth: Kirigami.Units.gridUnit * 34
    minimumHeight: Kirigami.Units.gridUnit * 28
    pageStack.globalToolBar.style: Kirigami.ApplicationHeaderStyle.None

    readonly property var d: bridge.input
    readonly property int score: d.score || 0
    readonly property color scoreColor: score >= 80 ? Kirigami.Theme.positiveTextColor
                                      : score >= 60 ? Kirigami.Theme.neutralTextColor
                                      : Kirigami.Theme.negativeTextColor

    // Values from the PC (host names, finding titles, paths) are text, never
    // markup: escaped where a label mixes them with bold labels.
    function esc(s) { return String(s === undefined ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
    function act(a, check) { bridge.finish(check ? { "action": a, "check": check } : { "action": a }) }
    function stateColor(s) {
        return s === "bad" ? Kirigami.Theme.negativeTextColor
             : s === "warn" ? Kirigami.Theme.linkColor
             : s === "reboot" ? Kirigami.Theme.linkColor
             : (s === "ok" || s === "fixed") ? Kirigami.Theme.positiveTextColor
             : Kirigami.Theme.disabledTextColor
    }
    function stateIcon(s) {
        // Low findings (warn) read as blue information everywhere: icon,
        // pill, summary and the header's "low" dot.
        return s === "bad" ? "dialog-error" : s === "warn" ? "dialog-information"
             : s === "reboot" ? "system-reboot" : (s === "ok" || s === "fixed") ? "dialog-ok-apply"
             : s === "note" ? "dialog-information" : s === "error" ? "dialog-error"
             : "dialog-cancel"
    }
    readonly property var sevs: [["high", "High", Kirigami.Theme.negativeTextColor], ["medium", "Medium", Kirigami.Theme.neutralTextColor],
                                 ["low", "Low", Kirigami.Theme.linkColor], ["info", "Info", Kirigami.Theme.disabledTextColor]]

    onClosing: bridge.cancel()

    pageStack.initialPage: Kirigami.Page {
        padding: 0
        titleDelegate: Item {}

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // ---- header: score, PC, open problems ----------------------
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: header.implicitHeight + Kirigami.Units.gridUnit * 1.5
                color: Kirigami.Theme.alternateBackgroundColor
                Kirigami.Theme.colorSet: Kirigami.Theme.Header
                Kirigami.Theme.inherit: false

                RowLayout {
                    id: header
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.gridUnit
                    spacing: Kirigami.Units.gridUnit * 1.5

                    // Score ring
                    Item {
                        implicitWidth: Kirigami.Units.gridUnit * 6.5
                        implicitHeight: implicitWidth
                        Canvas {
                            id: ring
                            anchors.fill: parent
                            property real frac: Math.max(0, Math.min(1, root.score / 100))
                            onWidthChanged: requestPaint()
                            Connections { target: root; function onScoreColorChanged() { ring.requestPaint() } }
                            onPaint: {
                                var c = getContext("2d"), r = width / 2 - 6
                                c.reset(); c.lineWidth = 9; c.lineCap = "round"
                                c.strokeStyle = Qt.rgba(0.5, 0.5, 0.5, 0.25)
                                c.beginPath(); c.arc(width / 2, height / 2, r, 0, 2 * Math.PI); c.stroke()
                                c.strokeStyle = root.scoreColor
                                c.beginPath(); c.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * frac); c.stroke()
                            }
                            Component.onCompleted: requestPaint()
                        }
                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 0
                            QQC2.Label {
                                Layout.alignment: Qt.AlignHCenter
                                text: root.score
                                font.pointSize: Kirigami.Theme.defaultFont.pointSize * 2.6
                                font.weight: Font.DemiBold
                                color: root.scoreColor
                            }
                            QQC2.Label {
                                Layout.alignment: Qt.AlignHCenter
                                text: "grade " + (root.d.grade || "?")
                                textFormat: Text.PlainText
                                opacity: 0.75
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Heading { text: "Security check-up"; level: 1 }
                        QQC2.Label {
                            Layout.fillWidth: true; wrapMode: Text.Wrap
                            textFormat: Text.StyledText
                            text: "<b>" + root.esc(root.d.host || "") + "</b> · " + root.esc(root.d.os || "") + (root.d.image ? " · " + root.esc(root.d.image) : "")
                        }
                        QQC2.Label {
                            Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.8
                            textFormat: Text.PlainText
                            text: (root.d.use || "") + " · " + (root.d.depth || "")
                                  + (root.d.score_was !== undefined && root.d.score_was !== root.score ? " · " + root.d.score_was + " when checked" : "")
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.largeSpacing
                            QQC2.Label { text: "Open:"; font.bold: true }
                            Repeater {
                                model: root.sevs
                                delegate: Row {
                                    spacing: Kirigami.Units.smallSpacing
                                    Rectangle {
                                        width: Kirigami.Units.gridUnit * 0.6; height: width; radius: width / 2
                                        color: modelData[2]; anchors.verticalCenter: parent.verticalCenter
                                    }
                                    QQC2.Label { text: ((root.d.open || {})[modelData[0]] || 0) + " " + modelData[1].toLowerCase() }
                                }
                            }
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

                    // ---- areas ------------------------------------------
                    Flow {
                        Layout.fillWidth: true
                        Layout.topMargin: Kirigami.Units.largeSpacing
                        Layout.leftMargin: Kirigami.Units.gridUnit
                        Layout.rightMargin: Kirigami.Units.gridUnit
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: root.d.areas || []
                            delegate: Rectangle {
                                radius: height / 2
                                implicitHeight: pill.implicitHeight + Kirigami.Units.smallSpacing * 2
                                implicitWidth: pill.implicitWidth + Kirigami.Units.largeSpacing * 2
                                color: Qt.rgba(root.stateColor(modelData.state).r, root.stateColor(modelData.state).g, root.stateColor(modelData.state).b, 0.14)
                                border.color: Qt.rgba(root.stateColor(modelData.state).r, root.stateColor(modelData.state).g, root.stateColor(modelData.state).b, 0.5)
                                RowLayout {
                                    id: pill
                                    anchors.centerIn: parent
                                    spacing: Kirigami.Units.smallSpacing
                                    Kirigami.Icon { source: root.stateIcon(modelData.state); implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth }
                                    QQC2.Label { text: modelData.name; textFormat: Text.PlainText }
                                }
                            }
                        }
                    }

                    // ---- notices ----------------------------------------
                    Kirigami.InlineMessage {
                        Layout.fillWidth: true; Layout.leftMargin: Kirigami.Units.gridUnit; Layout.rightMargin: Kirigami.Units.gridUnit
                        visible: !!root.d.reboot_reasons
                        type: Kirigami.MessageType.Warning
                        text: "<b>Reboot to finish:</b> " + root.esc(root.d.reboot_reasons || "")
                    }
                    Kirigami.InlineMessage {
                        Layout.fillWidth: true; Layout.leftMargin: Kirigami.Units.gridUnit; Layout.rightMargin: Kirigami.Units.gridUnit
                        visible: (root.d.fixed || 0) > 0
                        type: Kirigami.MessageType.Positive
                        text: "<b>Fixed in this run:</b> " + root.d.fixed + " (" + (root.d.verified || 0) + " checked again and gone"
                              + ((root.d.fixed_reboot || 0) > 0 ? ", " + root.d.fixed_reboot + " after a reboot" : "") + ")"
                    }
                    Kirigami.InlineMessage {
                        Layout.fillWidth: true; Layout.leftMargin: Kirigami.Units.gridUnit; Layout.rightMargin: Kirigami.Units.gridUnit
                        visible: root.d.prev === true
                        type: Kirigami.MessageType.Information
                        text: (root.d.gone || 0) + (root.d.new || 0) === 0 ? "<b>Since the last check:</b> no changes."
                            : "<b>Since the last check:</b> " + (root.d.gone || 0) + " resolved, " + (root.d.new || 0) + " new"
                              + (root.d.new_titles ? " - " + root.esc(root.d.new_titles) : "")
                    }
                    Kirigami.InlineMessage {
                        Layout.fillWidth: true; Layout.leftMargin: Kirigami.Units.gridUnit; Layout.rightMargin: Kirigami.Units.gridUnit
                        visible: root.d.report_only === true
                        type: Kirigami.MessageType.Information
                        text: "Report only: nothing on this PC will be changed in this run."
                    }
                    Kirigami.InlineMessage {
                        Layout.fillWidth: true; Layout.leftMargin: Kirigami.Units.gridUnit; Layout.rightMargin: Kirigami.Units.gridUnit
                        visible: !!root.d.report_note
                        type: Kirigami.MessageType.Warning
                        text: "<b>Report:</b> " + root.esc(root.d.report_note || "")
                    }

                    // ---- actions ----------------------------------------
                    Flow {
                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.gridUnit; Layout.rightMargin: Kirigami.Units.gridUnit
                        spacing: Kirigami.Units.smallSpacing
                        QQC2.Button {
                            visible: (root.d.nfix || 0) > 0
                            text: "Review and fix problems (" + (root.d.nfix || 0) + ")"
                            icon.name: "tools-wizard"
                            highlighted: true
                            font.bold: true
                            onClicked: root.act("fix")
                        }
                        QQC2.Button { text: "Open the full report"; icon.name: "document-preview"; onClicked: root.act("report") }
                        QQC2.Button { visible: root.d.undo === true; text: "Undo changes…"; icon.name: "edit-undo"; onClicked: root.act("undo") }
                        QQC2.Button {
                            visible: root.d.keep === true
                            text: "Kept on purpose…" + ((root.d.kept || 0) > 0 ? " (" + root.d.kept + ")" : "")
                            icon.name: "starred-symbolic"
                            onClicked: root.act("keep")
                            QQC2.ToolTip.visible: hovered
                            QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                            QQC2.ToolTip.text: "Keep problems you accept because you use the feature they are there for (Steam Remote Play, Sunshine, SSH, ...)."
                        }
                        QQC2.Button { text: "Settings"; icon.name: "configure"; onClicked: root.act("settings") }
                    }

                    // ---- checks, by area ----------------------------------
                    Kirigami.Heading {
                        Layout.leftMargin: Kirigami.Units.gridUnit
                        Layout.topMargin: Kirigami.Units.smallSpacing
                        level: 3
                        text: "Checks"
                    }
                    QQC2.Label {
                        Layout.leftMargin: Kirigami.Units.gridUnit
                        opacity: 0.75
                        text: "Open a check to see what it found and the settings it saw."
                    }
                    Repeater {
                        model: root.d.areas || []
                        delegate: ColumnLayout {
                            id: areaBlock
                            readonly property string area: modelData.name
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit; Layout.rightMargin: Kirigami.Units.gridUnit
                            spacing: 0
                            Kirigami.ListSectionHeader {
                                Layout.fillWidth: true; text: areaBlock.area
                                contentItem: QQC2.Label { text: areaBlock.area; textFormat: Text.PlainText; font.bold: true }
                            }
                            Repeater {
                                model: (root.d.checks || []).filter(function (c) { return c.area === areaBlock.area })
                                delegate: QQC2.ItemDelegate {
                                    Layout.fillWidth: true
                                    onClicked: root.act("check", modelData.id)
                                    Accessible.name: modelData.title + ", " + modelData.summary + ((modelData.affects || "") !== "" ? ", fix would stop " + modelData.affects : "")
                                    contentItem: RowLayout {
                                        spacing: Kirigami.Units.largeSpacing
                                        Kirigami.Icon {
                                            source: root.stateIcon(modelData.state)
                                            implicitWidth: Kirigami.Units.iconSizes.smallMedium; implicitHeight: implicitWidth
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0
                                            QQC2.Label { text: modelData.title; textFormat: Text.PlainText; Layout.fillWidth: true; elide: Text.ElideRight }
                                            QQC2.Label {
                                                visible: (modelData.affects || "") !== ""
                                                text: "Fix would stop " + (modelData.affects || "") + " (in use here)"
                                                textFormat: Text.PlainText
                                                font: Kirigami.Theme.smallFont
                                                opacity: 0.75
                                                Layout.fillWidth: true
                                                elide: Text.ElideRight
                                            }
                                        }
                                        QQC2.Label {
                                            text: modelData.summary
                                            textFormat: Text.PlainText
                                            color: (modelData.state === "ok" || modelData.state === "na") ? Kirigami.Theme.textColor : root.stateColor(modelData.state)
                                            opacity: (modelData.state === "ok" || modelData.state === "na") ? 0.7 : 1
                                            font.bold: modelData.state === "bad" || modelData.state === "warn"
                                            elide: Text.ElideRight
                                            Layout.maximumWidth: Kirigami.Units.gridUnit * 18
                                        }
                                        Kirigami.Icon { source: "go-next"; implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth; opacity: 0.6 }
                                    }
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
                    Layout.fillWidth: true
                    opacity: 0.7
                    text: "Score " + root.score + "/100. The report is saved; close this window when you are done."
                    elide: Text.ElideRight
                }
                // One primary button: Finish only when there is nothing to fix.
                QQC2.Button { text: "Finish"; icon.name: "dialog-ok"; highlighted: (root.d.nfix || 0) === 0; font.bold: highlighted; onClicked: root.act("finish") }
            }
        }
    }
}
