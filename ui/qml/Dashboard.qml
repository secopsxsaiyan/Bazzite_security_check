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
    // The colour of the grade: the ring has it as it is, the number in the
    // ring has it made readable as text (Util.ink).
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
    readonly property Item scrollArea: flick

    // The area chips are one stop for Tab, and so is the list of checks
    // (all areas together), as the lists of the Choose page and of a
    // dialog are: Tab stops at the current chip or row, and the arrow
    // keys, Home and End move between them.
    property int currentChip: 0
    property int currentCheck: 0
    readonly property var checkCounts: (d.areas || []).map(function (a) {
        return (d.checks || []).filter(function (c) { return c.area === a.name }).length })
    readonly property int checkTotal: checkCounts.reduce(function (sum, n) { return sum + n }, 0)
    // The number of the first check of area INDEX in the whole list.
    function firstOf(index) {
        var sum = 0
        for (var n = 0; n < index && n < checkCounts.length; n++) sum += checkCounts[n]
        return sum
    }
    function goToChip(n) {
        var chip = chipList.itemAt(Math.max(0, Math.min(chipList.count - 1, n)))
        if (chip) chip.forceActiveFocus(Qt.TabFocusReason)
    }
    function goToCheck(n) {
        n = Math.max(0, Math.min(checkTotal - 1, n))
        for (var a = 0; a < areaBlocks.count; a++) {
            var block = areaBlocks.itemAt(a)
            if (block && n >= block.first && n < block.first + block.rowCount) {
                block.rowAt(n - block.first).forceActiveFocus(Qt.TabFocusReason)
                return
            }
        }
    }
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
            title: page.title
            subtitle: [page.d.host || "", page.d.os || "", page.d.image || ""].filter(function (s) { return s !== "" }).join(" · ")

            leading: Item {
                implicitWidth: Kirigami.Units.gridUnit * 5.5
                implicitHeight: implicitWidth
                width: implicitWidth; height: implicitHeight
                Accessible.role: Accessible.StaticText
                Accessible.name: Util.fill(qsTr("Score %1 out of 100, grade %2"), [page.score, page.d.grade || "?"])
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
                        font.weight: Font.Bold
                        color: Util.ink(Kirigami.Theme, page.scoreColor)
                    }
                    QQC2.Label {
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("grade %1").arg(page.d.grade || "?")
                        textFormat: Text.PlainText
                        font: Kirigami.Theme.smallFont
                        opacity: Util.dimLabel
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                QQC2.Label {
                    Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: Util.dimText
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
                    // A count of none is a grey frame without a fill, so the
                    // eye goes to what is open; the others have the colour
                    // of their severity (information is grey everywhere).
                    StatusChip {
                        id: highChip
                        text: qsTr("%1 high").arg(page.open.high || 0)
                        quiet: (page.open.high || 0) === 0
                        tint: quiet ? Kirigami.Theme.disabledTextColor : Util.sevColor(Kirigami.Theme, "high")
                    }
                    StatusChip {
                        text: qsTr("%1 medium").arg(page.open.medium || 0)
                        quiet: (page.open.medium || 0) === 0
                        tint: quiet ? Kirigami.Theme.disabledTextColor : Util.sevColor(Kirigami.Theme, "medium")
                    }
                    StatusChip {
                        text: qsTr("%1 low").arg(page.open.low || 0)
                        quiet: (page.open.low || 0) === 0
                        tint: quiet ? Kirigami.Theme.disabledTextColor : Util.sevColor(Kirigami.Theme, "low")
                    }
                    StatusChip {
                        text: qsTr("%1 info").arg(page.open.info || 0)
                        quiet: (page.open.info || 0) === 0
                        tint: Util.sevColor(Kirigami.Theme, "info")
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
                    // The texts from the PC in these are plain text (Notice).
                    Notice {
                        visible: !!page.d.reboot_reasons
                        kind: "warning"
                        title: qsTr("Reboot to finish:")
                        text: page.d.reboot_reasons || ""
                    }
                    Notice {
                        visible: (page.d.fixed || 0) > 0
                        kind: "positive"
                        title: qsTr("Fixed in this run:")
                        text: (page.d.fixed_reboot || 0) > 0
                            ? qsTr("%1 (%2 checked again and gone, %3 after a reboot)")
                                .arg(page.d.fixed || 0).arg(page.d.verified || 0).arg(page.d.fixed_reboot || 0)
                            : qsTr("%1 (%2 checked again and gone)")
                                .arg(page.d.fixed || 0).arg(page.d.verified || 0)
                    }
                    Notice {
                        visible: page.d.prev === true
                        title: qsTr("Since the last check:")
                        text: (page.d.gone || 0) + (page.d["new"] || 0) === 0 ? qsTr("no changes.")
                            : page.d.new_titles
                                ? Util.fill(qsTr("%1 resolved, %2 new - %3"), [page.d.gone || 0, page.d["new"] || 0, page.d.new_titles])
                                : qsTr("%1 resolved, %2 new").arg(page.d.gone || 0).arg(page.d["new"] || 0)
                    }
                    Notice {
                        visible: page.d.report_only === true
                        text: qsTr("Report only: nothing on this PC will be changed in this run.")
                    }
                    Notice {
                        visible: !!page.d.report_note
                        kind: "warning"
                        title: qsTr("Report:")
                        text: page.d.report_note || ""
                    }

                    // ---- other things to do -------------------------------
                    // The main action (fix, or finish) is in the bar at the
                    // bottom; these are the side doors.
                    Flow {
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
                            opacity: Util.dimLabel
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
                                id: chipList
                                model: page.d.areas || []
                                delegate: QQC2.AbstractButton {
                                    id: chip
                                    required property var modelData
                                    required property int index
                                    readonly property color tint: Util.stateColor(Kirigami.Theme, modelData.state)
                                    // A long area name is cut instead of running off the page.
                                    width: Math.min(implicitWidth, chips.width)
                                    // One stop for Tab; Left and Right move
                                    // between the chips (Up and Down scroll).
                                    focusPolicy: index === page.currentChip ? Qt.StrongFocus : Qt.ClickFocus
                                    Keys.onRightPressed: page.goToChip(index + (mirrored ? -1 : 1))
                                    Keys.onLeftPressed: page.goToChip(index - (mirrored ? -1 : 1))
                                    Keys.onPressed: function (event) {
                                        if (event.key === Qt.Key_Home) page.goToChip(0)
                                        else if (event.key === Qt.Key_End) page.goToChip(chipList.count - 1)
                                        else return
                                        event.accepted = true
                                    }
                                    hoverEnabled: true
                                    leftPadding: Kirigami.Units.largeSpacing; rightPadding: Kirigami.Units.largeSpacing
                                    topPadding: Kirigami.Units.smallSpacing; bottomPadding: Kirigami.Units.smallSpacing
                                    Accessible.role: Accessible.Button
                                    Accessible.name: Util.fill(qsTr("%1: %2"), [modelData.name, Util.stateName(modelData.state)])
                                    Accessible.description: qsTr("Jump to this area in the list of checks")
                                    // Used with the keyboard when the focus came by Tab.
                                    onClicked: page.jumpTo(index, visualFocus)
                                    onActiveFocusChanged: if (activeFocus) {
                                        page.currentChip = index
                                        if (visualFocus) page.reveal(chip)
                                    }
                                    QQC2.ToolTip.visible: hovered
                                    QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                                    QQC2.ToolTip.text: Util.tip(Util.fill(qsTr("%1: %2"), [modelData.name, Util.stateName(modelData.state)]))
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
                            required property int index
                            readonly property string area: modelData.name
                            readonly property Item firstRow: rows.count > 0 ? rows.itemAt(0) : null
                            // Where its rows are in the list of all checks.
                            readonly property int first: page.firstOf(index)
                            readonly property int rowCount: rows.count
                            function rowAt(n) { return rows.itemAt(n) }
                            Layout.fillWidth: true
                            spacing: 0
                            Kirigami.ListSectionHeader {
                                Layout.fillWidth: true; text: areaBlock.area
                                Accessible.role: Accessible.Heading
                                Accessible.name: Util.fill(qsTr("%1: %2"), [areaBlock.area, Util.stateName(areaBlock.modelData.state)])
                                contentItem: QQC2.Label { text: areaBlock.area; textFormat: Text.PlainText; font.weight: Font.DemiBold; elide: Text.ElideRight }
                            }
                            Repeater {
                                id: rows
                                model: (page.d.checks || []).filter(function (c) { return c.area === areaBlock.area })
                                delegate: QQC2.ItemDelegate {
                                    id: row
                                    required property var modelData
                                    required property int index
                                    readonly property string state_: modelData.state || ""
                                    // Its number in the list of all checks.
                                    readonly property int number: areaBlock.first + index
                                    Layout.fillWidth: true
                                    // One stop for Tab; Up, Down, Home and End
                                    // move between the checks. Up on the first
                                    // and Down on the last are left to the
                                    // window, which scrolls the page.
                                    focusPolicy: number === page.currentCheck ? Qt.StrongFocus : Qt.ClickFocus
                                    Keys.onDownPressed: function (event) {
                                        if (number < page.checkTotal - 1) page.goToCheck(number + 1); else event.accepted = false
                                    }
                                    Keys.onUpPressed: function (event) {
                                        if (number > 0) page.goToCheck(number - 1); else event.accepted = false
                                    }
                                    Keys.onPressed: function (event) {
                                        if (event.key === Qt.Key_Home) page.goToCheck(0)
                                        else if (event.key === Qt.Key_End) page.goToCheck(page.checkTotal - 1)
                                        else return
                                        event.accepted = true
                                    }
                                    onClicked: page.act("check", modelData.id)
                                    onActiveFocusChanged: if (activeFocus) {
                                        page.currentCheck = number
                                        if (visualFocus) page.reveal(row)
                                    }
                                    Accessible.role: Accessible.Button
                                    Accessible.name: (modelData.affects || "") !== ""
                                        ? Util.fill(qsTr("%1, %2: %3. %4"), [modelData.title, Util.stateName(state_), modelData.summary || "", modelData.affects])
                                        : Util.fill(qsTr("%1, %2: %3"), [modelData.title, Util.stateName(state_), modelData.summary || ""])
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
                                                opacity: Util.dimLabel
                                                Layout.fillWidth: true
                                                wrapMode: Text.Wrap
                                                maximumLineCount: 2
                                                elide: Text.ElideRight
                                                // The whole line when it is cut off.
                                                QQC2.ToolTip.visible: truncated && affectsHover.hovered
                                                QQC2.ToolTip.text: Util.tip(text)
                                                HoverHandler { id: affectsHover }
                                            }
                                        }
                                        QQC2.Label {
                                            text: row.modelData.summary || ""
                                            textFormat: Text.PlainText
                                            // Medium only (no high) reads orange, like the header's count
                                            // (a colour made readable as text: Util.ink). The icon in front
                                            // of the row and the words say the state.
                                            color: Util.summaryColor(Kirigami.Theme, row.state_, text)
                                            opacity: (row.state_ === "ok" || row.state_ === "na") ? Util.dimQuiet : 1
                                            font.weight: row.state_ === "bad" || row.state_ === "warn" ? Font.DemiBold : Font.Normal
                                            horizontalAlignment: Text.AlignRight
                                            wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                                            Layout.maximumWidth: Math.min(Kirigami.Units.gridUnit * 18, content.width * 0.38)
                                        }
                                        Kirigami.Icon { source: "go-next"; implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth; opacity: Util.dimMark; Accessible.ignored: true }
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
