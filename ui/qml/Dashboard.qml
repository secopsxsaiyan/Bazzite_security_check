// Security Check - the result of the check-up, a page of the main window:
// the score, what happened in this run, and every check by area.
// finished({action, check}) answers; the root side validates the action and
// the check id.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

Item {
    id: page
    required property var input
    property string iconSource: ""
    readonly property string title: qsTr("Check-up result")
    signal finished(var answer)
    signal cancelled()

    readonly property var d: input || ({})
    readonly property int score: d.score || 0
    readonly property color scoreColor: score >= 80 ? Kirigami.Theme.positiveTextColor
                                      : score >= 60 ? Kirigami.Theme.neutralTextColor
                                      : Kirigami.Theme.negativeTextColor
    readonly property var open: d.open || ({})
    readonly property int openTotal: (open.high || 0) + (open.medium || 0) + (open.low || 0) + (open.info || 0)
    // Fixes are on offer only when the run may change the PC.
    readonly property bool canFix: (d.nfix || 0) > 0 && d.report_only !== true

    function primary() { act(canFix ? "fix" : "finish") }
    // Esc does nothing here: this is where Esc on a check comes back to, and
    // a second Esc must not end the run. Finish (or closing the window) does.
    function dismiss() {}
    function initialFocus() { return mainButton }

    function act(a, check) { finished(check ? { "action": a, "check": check } : { "action": a }) }

    // Scroll so that an item that got keyboard focus is in view.
    function reveal(item) { Util.reveal(flick, item, Kirigami.Units.largeSpacing) }
    function scrollTo(y) { flick.contentY = Math.max(0, Math.min(y, flick.contentHeight - flick.height)) }
    // An area chip was used: show that area's checks, and when it was used
    // with the keyboard carry on from its first check.
    function jumpTo(index, byKeyboard) {
        var block = areaBlocks.itemAt(index)
        if (!block)
            return
        scrollTo(block.mapToItem(flick.contentItem, 0, 0).y - Kirigami.Units.smallSpacing)
        if (byKeyboard && block.firstRow)
            block.firstRow.forceActiveFocus(Qt.TabFocusReason)
    }

    // One of the side doors: comes into view with the keyboard focus.
    component ActionButton: QQC2.Button {
        onActiveFocusChanged: if (activeFocus && visualFocus) page.reveal(this)
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- header: score, PC, open problems ------------------------------
        PageHeader {
            title: qsTr("Security check-up")
            subtitle: [page.d.host || "", page.d.os || "", page.d.image || ""].filter(function (s) { return s !== "" }).join(" · ")

            leading: Item {
                implicitWidth: Kirigami.Units.gridUnit * 5.5
                implicitHeight: implicitWidth
                width: implicitWidth; height: implicitHeight
                Accessible.role: Accessible.StaticText
                Accessible.name: qsTr("Score %1 out of 100, grade %2").arg(page.score).arg(page.d.grade || "?")
                Canvas {
                    id: ring
                    anchors.fill: parent
                    readonly property real frac: Math.max(0, Math.min(1, page.score / 100))
                    readonly property real line: Kirigami.Units.smallSpacing * 2
                    readonly property color track: Qt.alpha(Kirigami.Theme.textColor, 0.18)
                    onWidthChanged: requestPaint()
                    onTrackChanged: requestPaint()
                    onFracChanged: requestPaint()
                    Connections { target: page; function onScoreColorChanged() { ring.requestPaint() } }
                    onPaint: {
                        var c = getContext("2d"), r = (width - line) / 2 - 1
                        c.reset(); c.lineWidth = line; c.lineCap = "round"
                        c.strokeStyle = track
                        c.beginPath(); c.arc(width / 2, height / 2, r, 0, 2 * Math.PI); c.stroke()
                        if (frac > 0) {
                            c.strokeStyle = page.scoreColor
                            c.beginPath(); c.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * frac); c.stroke()
                        }
                    }
                    Component.onCompleted: requestPaint()
                }
                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 0
                    QQC2.Label {
                        Layout.alignment: Qt.AlignHCenter
                        text: page.score
                        font.pointSize: Kirigami.Theme.defaultFont.pointSize * 2.2
                        font.weight: Font.DemiBold
                        color: page.scoreColor
                    }
                    QQC2.Label {
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("grade %1").arg(page.d.grade || "?")
                        textFormat: Text.PlainText
                        font: Kirigami.Theme.smallFont
                        opacity: 0.75
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                QQC2.Label {
                    Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.8
                    textFormat: Text.PlainText
                    visible: text !== ""
                    text: {
                        var parts = [page.d.use || "", page.d.depth || ""].filter(function (s) { return s !== "" })
                        if (page.d.score_was !== undefined && page.d.score_was !== page.score)
                            parts.push(qsTr("%1 when checked").arg(page.d.score_was))
                        return parts.join(" · ")
                    }
                }
                Flow {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing
                    Accessible.role: Accessible.StaticText
                    Accessible.name: qsTr("Open problems: %1 high, %2 medium, %3 low, %4 info")
                        .arg(page.open.high || 0).arg(page.open.medium || 0).arg(page.open.low || 0).arg(page.open.info || 0)
                    QQC2.Label { text: qsTr("Open:"); height: highChip.height; verticalAlignment: Text.AlignVCenter }
                    // A count of none is grey, so the eye goes to what is open.
                    StatusChip {
                        id: highChip
                        text: qsTr("%1 high").arg(page.open.high || 0)
                        tint: (page.open.high || 0) > 0 ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.disabledTextColor
                    }
                    StatusChip {
                        text: qsTr("%1 medium").arg(page.open.medium || 0)
                        tint: (page.open.medium || 0) > 0 ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.disabledTextColor
                    }
                    StatusChip {
                        text: qsTr("%1 low").arg(page.open.low || 0)
                        tint: (page.open.low || 0) > 0 ? Kirigami.Theme.linkColor : Kirigami.Theme.disabledTextColor
                    }
                    StatusChip {
                        text: qsTr("%1 info").arg(page.open.info || 0)
                        tint: (page.open.info || 0) > 0 ? Kirigami.Theme.textColor : Kirigami.Theme.disabledTextColor
                    }
                }
            }
        }

        QQC2.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            Flickable {
                id: flick
                contentWidth: width
                contentHeight: content.implicitHeight + Kirigami.Units.gridUnit * 2
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: content
                    x: Kirigami.Units.gridUnit
                    y: Kirigami.Units.gridUnit
                    // Lines of text stay readable on a wide window.
                    width: Math.min(flick.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 56)
                    spacing: Kirigami.Units.largeSpacing

                    // ---- what happened in this run ------------------------
                    Kirigami.InlineMessage {
                        Layout.fillWidth: true
                        visible: !!page.d.reboot_reasons
                        type: Kirigami.MessageType.Warning
                        text: qsTr("<b>Reboot to finish:</b> %1").arg(Util.esc(page.d.reboot_reasons || ""))
                    }
                    Kirigami.InlineMessage {
                        Layout.fillWidth: true
                        visible: (page.d.fixed || 0) > 0
                        type: Kirigami.MessageType.Positive
                        text: (page.d.fixed_reboot || 0) > 0
                            ? qsTr("<b>Fixed in this run:</b> %1 (%2 checked again and gone, %3 after a reboot)")
                                .arg(page.d.fixed || 0).arg(page.d.verified || 0).arg(page.d.fixed_reboot || 0)
                            : qsTr("<b>Fixed in this run:</b> %1 (%2 checked again and gone)")
                                .arg(page.d.fixed || 0).arg(page.d.verified || 0)
                    }
                    Kirigami.InlineMessage {
                        Layout.fillWidth: true
                        visible: page.d.prev === true
                        type: Kirigami.MessageType.Information
                        text: (page.d.gone || 0) + (page.d["new"] || 0) === 0 ? qsTr("<b>Since the last check:</b> no changes.")
                            : page.d.new_titles
                                ? qsTr("<b>Since the last check:</b> %1 resolved, %2 new - %3")
                                    .arg(page.d.gone || 0).arg(page.d["new"] || 0).arg(Util.esc(page.d.new_titles))
                                : qsTr("<b>Since the last check:</b> %1 resolved, %2 new").arg(page.d.gone || 0).arg(page.d["new"] || 0)
                    }
                    Kirigami.InlineMessage {
                        Layout.fillWidth: true
                        visible: page.d.report_only === true
                        type: Kirigami.MessageType.Information
                        text: qsTr("Report only: nothing on this PC will be changed in this run.")
                    }
                    Kirigami.InlineMessage {
                        Layout.fillWidth: true
                        visible: !!page.d.report_note
                        type: Kirigami.MessageType.Warning
                        text: qsTr("<b>Report:</b> %1").arg(Util.esc(page.d.report_note || ""))
                    }

                    // ---- other things to do -------------------------------
                    // The main action (fix, or finish) is in the bar at the
                    // bottom; these are the side doors.
                    Flow {
                        id: actions
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        ActionButton { text: qsTr("Open the full report"); icon.name: "document-preview"; onClicked: page.act("report") }
                        ActionButton { visible: page.d.undo === true; text: qsTr("Undo changes…"); icon.name: "edit-undo"; onClicked: page.act("undo") }
                        ActionButton {
                            visible: page.d.keep === true
                            text: (page.d.kept || 0) > 0 ? qsTr("Kept on purpose… (%1)").arg(page.d.kept) : qsTr("Kept on purpose…")
                            icon.name: "starred-symbolic"
                            onClicked: page.act("keep")
                            QQC2.ToolTip.visible: hovered
                            QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                            QQC2.ToolTip.text: qsTr("Keep problems you accept because you use the feature they are there for (Steam Remote Play, Sunshine, SSH, ...).")
                            Accessible.description: QQC2.ToolTip.text
                        }
                        ActionButton { text: qsTr("Settings"); icon.name: "configure"; onClicked: page.act("settings") }
                    }

                    // ---- checks, by area ----------------------------------
                    Section {
                        Layout.topMargin: Kirigami.Units.smallSpacing
                        title: qsTr("Checks")
                        QQC2.Label {
                            Layout.fillWidth: true; wrapMode: Text.Wrap
                            opacity: 0.75
                            text: (page.d.checks || []).length === 0 ? qsTr("No checks were run.")
                                : qsTr("Open a check to see what it found and the settings it saw. Pick an area to jump to it.")
                        }

                        // One chip per area: its state, and a jump to its checks.
                        Flow {
                            id: chips
                            Layout.fillWidth: true
                            Layout.topMargin: Kirigami.Units.smallSpacing
                            visible: (page.d.areas || []).length > 0
                            spacing: Kirigami.Units.smallSpacing
                            Repeater {
                                model: page.d.areas || []
                                delegate: QQC2.AbstractButton {
                                    id: chip
                                    required property var modelData
                                    required property int index
                                    readonly property color tint: Util.stateColor(Kirigami.Theme, modelData.state)
                                    // A long area name is cut instead of running off the page.
                                    width: Math.min(implicitWidth, chips.width)
                                    focusPolicy: Qt.StrongFocus
                                    hoverEnabled: true
                                    leftPadding: Kirigami.Units.largeSpacing; rightPadding: Kirigami.Units.largeSpacing
                                    topPadding: Kirigami.Units.smallSpacing; bottomPadding: Kirigami.Units.smallSpacing
                                    Accessible.role: Accessible.Button
                                    Accessible.name: qsTr("%1: %2").arg(modelData.name).arg(Util.stateName(modelData.state))
                                    Accessible.description: qsTr("Jump to this area in the list of checks")
                                    // Used with the keyboard when the focus came by Tab.
                                    onClicked: page.jumpTo(index, visualFocus)
                                    onActiveFocusChanged: if (activeFocus && visualFocus) page.reveal(chip)
                                    QQC2.ToolTip.visible: hovered
                                    QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                                    QQC2.ToolTip.text: qsTr("%1: %2").arg(modelData.name).arg(Util.stateName(modelData.state))
                                    contentItem: RowLayout {
                                        spacing: Kirigami.Units.smallSpacing
                                        Kirigami.Icon {
                                            source: Util.stateIcon(chip.modelData.state)
                                            implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth
                                            Accessible.ignored: true    // the chip's name says it
                                        }
                                        QQC2.Label { Layout.fillWidth: true; text: chip.modelData.name; textFormat: Text.PlainText; elide: Text.ElideRight }
                                    }
                                    background: Rectangle {
                                        radius: height / 2
                                        color: Qt.alpha(chip.tint, chip.down ? 0.4 : chip.hovered ? 0.28 : 0.14)
                                        border.color: Qt.alpha(chip.tint, 0.5)
                                        FocusRing { target: chip; cornerRadius: parent.radius }
                                    }
                                }
                            }
                        }
                    }

                    Repeater {
                        id: areaBlocks
                        model: page.d.areas || []
                        delegate: ColumnLayout {
                            id: areaBlock
                            required property var modelData
                            readonly property string area: modelData.name
                            readonly property Item firstRow: rows.count > 0 ? rows.itemAt(0) : null
                            Layout.fillWidth: true
                            spacing: 0
                            Kirigami.ListSectionHeader {
                                Layout.fillWidth: true; text: areaBlock.area
                                Accessible.role: Accessible.Heading
                                Accessible.name: qsTr("%1: %2").arg(areaBlock.area).arg(Util.stateName(areaBlock.modelData.state))
                                contentItem: QQC2.Label { text: areaBlock.area; textFormat: Text.PlainText; font.weight: Font.DemiBold; elide: Text.ElideRight }
                            }
                            Repeater {
                                id: rows
                                model: (page.d.checks || []).filter(function (c) { return c.area === areaBlock.area })
                                delegate: QQC2.ItemDelegate {
                                    id: row
                                    required property var modelData
                                    readonly property string state_: modelData.state || ""
                                    Layout.fillWidth: true
                                    focusPolicy: Qt.StrongFocus
                                    onClicked: page.act("check", modelData.id)
                                    onActiveFocusChanged: if (activeFocus && visualFocus) page.reveal(row)
                                    Accessible.role: Accessible.Button
                                    Accessible.name: (modelData.affects || "") !== ""
                                        ? qsTr("%1, %2: %3. %4").arg(modelData.title).arg(Util.stateName(state_)).arg(modelData.summary || "").arg(modelData.affects)
                                        : qsTr("%1, %2: %3").arg(modelData.title).arg(Util.stateName(state_)).arg(modelData.summary || "")
                                    Accessible.description: qsTr("Opens this check")
                                    // Inside the row: the rows touch each other.
                                    FocusRing { target: row; outset: 0; z: 1 }
                                    contentItem: RowLayout {
                                        spacing: Kirigami.Units.largeSpacing
                                        Kirigami.Icon {
                                            source: Util.stateIcon(row.state_)
                                            implicitWidth: Kirigami.Units.iconSizes.smallMedium; implicitHeight: implicitWidth
                                            Accessible.ignored: true    // the row's name says it
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0
                                            QQC2.Label {
                                                text: row.modelData.title; textFormat: Text.PlainText
                                                Layout.fillWidth: true
                                                wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                                            }
                                            QQC2.Label {
                                                visible: (row.modelData.affects || "") !== ""
                                                text: row.modelData.affects || ""
                                                textFormat: Text.PlainText
                                                font: Kirigami.Theme.smallFont
                                                opacity: 0.75
                                                Layout.fillWidth: true
                                                wrapMode: Text.Wrap
                                                maximumLineCount: 2
                                                elide: Text.ElideRight
                                                // The whole line when it is cut off.
                                                QQC2.ToolTip.visible: truncated && affectsHover.hovered
                                                QQC2.ToolTip.text: text
                                                HoverHandler { id: affectsHover }
                                            }
                                        }
                                        QQC2.Label {
                                            text: row.modelData.summary || ""
                                            textFormat: Text.PlainText
                                            // Medium only (no high) reads orange, like the header's count.
                                            color: (row.state_ === "ok" || row.state_ === "na") ? Kirigami.Theme.textColor
                                                 : row.state_ === "bad" && text.indexOf(" high") < 0 ? Kirigami.Theme.neutralTextColor
                                                 : Util.stateColor(Kirigami.Theme, row.state_)
                                            opacity: (row.state_ === "ok" || row.state_ === "na") ? 0.7 : 1
                                            font.weight: row.state_ === "bad" || row.state_ === "warn" ? Font.DemiBold : Font.Normal
                                            horizontalAlignment: Text.AlignRight
                                            wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                                            Layout.maximumWidth: Math.min(Kirigami.Units.gridUnit * 18, content.width * 0.38)
                                        }
                                        Kirigami.Icon { source: "go-next"; implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth; opacity: 0.6; Accessible.ignored: true }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        FooterBar {
            hint: page.canFix ? qsTr("Each fix is shown with its exact commands before anything is changed.")
                : page.openTotal === 0 ? qsTr("No open problems. The report is saved.")
                : qsTr("The report is saved.")
            // Finish is the main button only when there is nothing to fix.
            QQC2.Button { visible: page.canFix; text: qsTr("Finish"); icon.name: "dialog-ok"; onClicked: page.act("finish") }
            PrimaryButton {
                id: mainButton
                text: page.canFix ? qsTr("Review and fix problems (%1)").arg(page.d.nfix || 0) : qsTr("Finish")
                icon.name: page.canFix ? "tools-wizard" : "dialog-ok"
                onClicked: page.primary()
            }
        }
    }
}
