// Security Check - one check, a page of the main window: what the check saw
// and each finding as a card, with what the fix changes, what it affects on
// Bazzite, its side effects and the manual steps. Every finding that can be
// fixed has its own tick box, plus Select all.
// finished({action: "fix", ids: [...]}) or {action: "back"} answers; the
// root side keeps only ids it offered.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Item {
    id: page
    required property var input
    property string iconSource: ""
    readonly property string title: d.title || qsTr("Check")
    signal finished(var answer)
    signal cancelled()

    readonly property var d: input || ({})
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
        finished({ "action": "fix", "ids": fixable.filter(function (f) { return picked[f.id] === true }).map(function (f) { return f.id }) })
    }
    function back() { finished({ "action": "back" }) }
    function primary() { if (fixable.length > 0 && count > 0) fix(); else back() }
    // Esc goes back to the list of checks, it does not end the run.
    function dismiss() { back() }

    function sevColor(s) {
        return s === "high" ? Kirigami.Theme.negativeTextColor : s === "medium" ? Kirigami.Theme.neutralTextColor
             : s === "low" ? Kirigami.Theme.linkColor : Kirigami.Theme.disabledTextColor
    }
    function sevName(s) {
        return s === "high" ? qsTr("High severity") : s === "medium" ? qsTr("Medium severity")
             : s === "low" ? qsTr("Low severity") : qsTr("Information")
    }
    function stateIcon(s) {
        return s === "bad" ? "dialog-error" : s === "warn" ? "dialog-information"
             : s === "reboot" ? "system-reboot" : (s === "ok" || s === "fixed") ? "dialog-ok-apply"
             : s === "note" ? "dialog-information" : s === "error" ? "dialog-error" : "dialog-cancel"
    }
    // The state in words, for screen readers: the icon says it only to the eye.
    function stateName(s) {
        return s === "bad" ? qsTr("Problems found") : s === "warn" ? qsTr("Minor findings")
             : s === "reboot" ? qsTr("Needs a reboot") : s === "ok" ? qsTr("No problems")
             : s === "fixed" ? qsTr("Fixed") : s === "note" ? qsTr("Has notes")
             : s === "error" ? qsTr("Could not be checked") : s === "skipped" ? qsTr("Skipped")
             : qsTr("Does not apply")
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

    // Scroll so that an item that got keyboard focus is in view.
    function reveal(item) {
        var top = item.mapToItem(flick.contentItem, 0, 0).y, gap = Kirigami.Units.gridUnit
        if (top - gap < flick.contentY)
            flick.contentY = Math.max(0, top - gap)
        else if (top + item.height + gap > flick.contentY + flick.height)
            flick.contentY = Math.max(0, Math.min(top + item.height + gap, flick.contentHeight) - flick.height)
    }

    // A button that is not the page's main one. Enter presses the button
    // that has the keyboard focus instead of the page's main button.
    component PlainButton: QQC2.Button {
        Keys.onShortcutOverride: function (event) { event.accepted = event.key === Qt.Key_Return || event.key === Qt.Key_Enter }
        Keys.onReturnPressed: clicked()
        Keys.onEnterPressed: clicked()
    }
    // The same inside the scrolling part: comes into view with the focus.
    component InlineButton: PlainButton {
        flat: true
        Layout.leftMargin: -leftPadding      // its icon lines up with the text above
        onActiveFocusChanged: if (activeFocus && visualFocus) page.reveal(this)
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        PageHeader {
            title: page.d.title || ""
            subtitle: [page.d.area || "", page.d.summary || ""].filter(function (s) { return s !== "" }).join(" · ")
            leading: Kirigami.Icon {
                source: page.stateIcon(page.d.state || "")
                width: Kirigami.Units.iconSizes.large; height: width
                Accessible.role: Accessible.Graphic
                Accessible.name: page.stateName(page.d.state || "")
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
                    width: Math.min(flick.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 48)
                    spacing: Kirigami.Units.largeSpacing

                    // ---- what the check saw -------------------------------
                    Section {
                        title: qsTr("What the check saw")
                        visible: (page.d.notes || []).length > 0
                        Repeater {
                            model: page.d.notes || []
                            delegate: RowLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing
                                Accessible.role: Accessible.ListItem
                                Accessible.name: String(modelData)
                                QQC2.Label { text: "•"; opacity: 0.75; Layout.alignment: Qt.AlignTop; Accessible.ignored: true }
                                QQC2.Label { Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: String(parent.modelData) }
                            }
                        }
                    }

                    // ---- findings -----------------------------------------
                    Section {
                        Layout.topMargin: (page.d.notes || []).length > 0 ? Kirigami.Units.smallSpacing : 0
                        title: page.findings.length > 0 ? qsTr("What it found (%1)").arg(page.findings.length) : qsTr("What it found")
                        QQC2.Label {
                            Layout.fillWidth: true; wrapMode: Text.Wrap
                            visible: page.findings.length === 0
                            opacity: 0.8
                            text: qsTr("Nothing to report.")
                        }
                        QQC2.CheckBox {
                            visible: page.fixable.length > 1
                            text: qsTr("Select all %1 that can be fixed here").arg(page.fixable.length)
                            // Some but not all ticked shows as a partial tick.
                            checkState: page.count === 0 ? Qt.Unchecked : page.count === page.fixable.length ? Qt.Checked : Qt.PartiallyChecked
                            nextCheckState: function () { return page.count === page.fixable.length ? Qt.Unchecked : Qt.Checked }
                            // All of them, unless all are ticked already.
                            onClicked: page.setAll(page.count !== page.fixable.length)
                            onActiveFocusChanged: if (activeFocus && visualFocus) page.reveal(this)
                        }
                    }

                    Repeater {
                        model: page.findings
                        delegate: Rectangle {
                            id: card
                            required property var modelData
                            readonly property var f: modelData
                            readonly property bool canFix: f.fixable === true
                            readonly property bool on: canFix && page.picked[f.id] === true
                            readonly property color tint: page.sevColor(f.sev)
                            readonly property bool longDetail: (f.detail || "").split("\n").length > 6 || (f.detail || "").length > 600
                            property bool more: false
                            property bool manualOpen: false
                            Layout.fillWidth: true
                            implicitHeight: cardBody.implicitHeight + Kirigami.Units.largeSpacing * 2
                            radius: Kirigami.Units.cornerRadius
                            Kirigami.Theme.colorSet: Kirigami.Theme.View
                            Kirigami.Theme.inherit: false
                            // Selection is a soft tint of the whole card; the
                            // severity strip on the left never changes.
                            color: on ? Kirigami.ColorUtils.tintWithAlpha(Kirigami.Theme.backgroundColor, Kirigami.Theme.highlightColor, 0.12)
                                      : Kirigami.Theme.backgroundColor
                            border.width: 1
                            border.color: on ? Kirigami.ColorUtils.tintWithAlpha(Kirigami.Theme.backgroundColor, Kirigami.Theme.highlightColor, 0.55)
                                             : Kirigami.ColorUtils.tintWithAlpha(Kirigami.Theme.backgroundColor, Kirigami.Theme.textColor, 0.2)
                            Accessible.role: Accessible.Grouping
                            Accessible.name: qsTr("%1: %2").arg(page.sevName(f.sev)).arg(f.title || "")

                            Rectangle {
                                id: strip
                                anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                                anchors.margins: Kirigami.Units.smallSpacing
                                width: Kirigami.Units.smallSpacing
                                radius: width / 2
                                color: card.tint
                            }

                            ColumnLayout {
                                id: cardBody
                                anchors.left: strip.right; anchors.right: parent.right; anchors.top: parent.top
                                anchors.leftMargin: Kirigami.Units.largeSpacing
                                anchors.rightMargin: Kirigami.Units.largeSpacing
                                anchors.topMargin: Kirigami.Units.largeSpacing
                                spacing: Kirigami.Units.largeSpacing

                                // ---- tick box, title, severity ------------
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing
                                    QQC2.CheckBox {
                                        id: tick
                                        visible: card.canFix
                                        Layout.alignment: Qt.AlignTop
                                        checked: card.on
                                        onToggled: page.toggle(card.f.id, checked)
                                        onActiveFocusChanged: if (activeFocus && visualFocus) page.reveal(card)
                                        Accessible.name: qsTr("Fix: %1").arg(card.f.title || "")
                                        QQC2.ToolTip.text: qsTr("Fix this one")
                                        QQC2.ToolTip.visible: hovered
                                        QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0
                                        QQC2.Label {
                                            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                                            font.weight: Font.DemiBold; text: card.f.title || ""
                                            Accessible.role: Accessible.Heading
                                            // The title works as the tick box's label.
                                            TapHandler { enabled: card.canFix; onTapped: page.toggle(card.f.id, !card.on) }
                                        }
                                        QQC2.Label {
                                            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                                            visible: text !== ""
                                            opacity: 0.75; text: card.f.status || ""
                                        }
                                    }
                                    StatusChip {
                                        Layout.alignment: Qt.AlignTop
                                        sev: card.f.sev || "info"
                                        text: page.sevName(card.f.sev)
                                    }
                                }

                                NowAfter {
                                    now: card.f.now || ""
                                    after: card.f.after || ""
                                    afterLabel: card.f.after_label || qsTr("After")
                                }

                                // ---- description: the first lines, the rest on request
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: (card.f.detail || "") !== ""
                                    spacing: 0
                                    QQC2.Label {
                                        Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                                        text: page.reflow(card.f.detail)
                                        maximumLineCount: card.more ? 100000 : 6
                                        elide: Text.ElideRight
                                    }
                                    InlineButton {
                                        visible: card.longDetail
                                        text: card.more ? qsTr("Show less") : qsTr("Show all details")
                                        icon.name: card.more ? "go-up" : "go-down"
                                        onClicked: card.more = !card.more
                                    }
                                }

                                AffectsList { model: card.f.affects || [] }

                                WarningsBox { warnings: card.f.warnings || [] }

                                // ---- how to fix it yourself: closed until asked for
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: !!card.f.manual
                                    spacing: Kirigami.Units.smallSpacing
                                    InlineButton {
                                        text: qsTr("How to fix it yourself")
                                        icon.name: card.manualOpen ? "go-down" : "go-next"
                                        // The steps open below the button: bring them into view.
                                        onClicked: { card.manualOpen = !card.manualOpen; steps.justOpened = card.manualOpen }
                                        Accessible.description: card.manualOpen ? qsTr("Hides the manual steps") : qsTr("Shows the manual steps")
                                    }
                                    CodeBlock {
                                        id: steps
                                        // Set by the button; the scroll waits for the layout to give the block its height.
                                        property bool justOpened: false
                                        onHeightChanged: if (justOpened && height > 0) { justOpened = false; page.reveal(steps) }
                                        visible: card.manualOpen; text: card.f.manual || "" }
                                }
                            }
                        }
                    }
                }
            }
        }

        FooterBar {
            hint: page.fixable.length > 0
                ? qsTr("Each selected fix is shown again with its exact commands, and runs only when you press Apply.")
                : ""
            // Back is the main button only when nothing can be fixed here.
            PlainButton { visible: page.fixable.length > 0; text: qsTr("Back"); icon.name: "go-previous"; onClicked: page.back() }
            PrimaryButton {
                text: page.fixable.length > 0 ? qsTr("Fix selected (%1)").arg(page.count) : qsTr("Back")
                icon.name: page.fixable.length > 0 ? "tools-wizard" : "go-previous"
                enabled: page.fixable.length === 0 || page.count > 0
                onClicked: page.primary()
            }
        }
    }
}
