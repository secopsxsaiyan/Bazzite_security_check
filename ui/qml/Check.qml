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
import "util.js" as Util

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
    // Enter is the main button: "Fix selected", which does nothing while
    // nothing is ticked, or "Back" when nothing here can be fixed.
    function primary() { if (fixable.length === 0) back(); else if (count > 0) fix() }
    // Esc goes back to the list of checks, it does not end the run.
    function dismiss() { back() }
    // The main button, or while it cannot be used the first tick box (Space
    // ticks it): not Back, where Enter would leave the page.
    function initialFocus() {
        if (mainButton.enabled) return mainButton
        if (selectAll.visible) return selectAll
        for (var n = 0; n < cards.count; n++)
            if (cards.itemAt(n).canFix) return cards.itemAt(n).tickBox
        return null
    }

    // Scroll so that an item that got keyboard focus is in view.
    function reveal(item) { Util.reveal(flick, item, Kirigami.Units.gridUnit) }
    readonly property Item scrollArea: flick

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        PageHeader {
            title: page.d.title || qsTr("Check")
            subtitle: [page.d.area || "", page.d.summary || ""].filter(function (s) { return s !== "" }).join(" · ")
            leading: Kirigami.Icon {
                source: Util.stateIcon(page.d.state || "")
                width: Kirigami.Units.iconSizes.large; height: width
                Accessible.role: Accessible.Graphic
                Accessible.name: Util.stateName(page.d.state || "")
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
                                QQC2.Label { text: "•"; opacity: Util.dimLabel; Layout.alignment: Qt.AlignTop; Accessible.ignored: true }
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
                            opacity: Util.dimText
                            text: qsTr("Nothing to report.")
                        }
                        QQC2.CheckBox {
                            id: selectAll
                            visible: page.fixable.length > 1
                            text: qsTr("Select all %1 that can be fixed here").arg(page.fixable.length)
                            // Some but not all ticked shows as a partial tick.
                            checkState: page.count === 0 ? Qt.Unchecked : page.count === page.fixable.length ? Qt.Checked : Qt.PartiallyChecked
                            nextCheckState: function () { return page.count === page.fixable.length ? Qt.Unchecked : Qt.Checked }
                            // All of them, unless all are ticked already.
                            onClicked: page.setAll(page.count !== page.fixable.length)
                            onActiveFocusChanged: if (activeFocus && visualFocus) page.reveal(this)
                            // The style shows no keyboard focus on a tick box.
                            FocusRing { target: selectAll }
                        }
                    }

                    Repeater {
                        id: cards
                        model: page.findings
                        delegate: Rectangle {
                            id: card
                            required property var modelData
                            property alias tickBox: tick
                            readonly property var f: modelData
                            readonly property bool canFix: f.fixable === true
                            readonly property bool on: canFix && page.picked[f.id] === true
                            readonly property color tint: Util.sevColor(Kirigami.Theme, f.sev)
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
                            Accessible.name: Util.fill(qsTr("%1: %2"), [Util.sevName(f.sev), f.title || ""])

                            // The tick box has no label of its own and the
                            // style shows no keyboard focus on it: the ring
                            // goes around the card it ticks.
                            FocusRing { target: tick; cornerRadius: card.radius }

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
                                            opacity: Util.dimLabel; text: card.f.status || ""
                                        }
                                    }
                                    StatusChip {
                                        Layout.alignment: Qt.AlignTop
                                        sev: card.f.sev || "info"
                                    }
                                }

                                NowAfter {
                                    now: card.f.now || ""
                                    after: card.f.after || ""
                                    afterLabel: card.f.after_label || ""
                                }

                                // ---- description: the first lines, the rest on request
                                ExpandableText { text: card.f.detail || ""; flickable: flick }

                                AffectsList { model: card.f.affects || [] }

                                WarningsBox { warnings: card.f.warnings || [] }

                                // ---- how to fix it yourself: closed until asked for
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: !!card.f.manual
                                    spacing: Kirigami.Units.smallSpacing
                                    QQC2.Button {
                                        flat: true
                                        // Its icon lines up with the text above: the style keeps
                                        // about this much room left of the icon of a flat button
                                        // (and says so nowhere: its leftPadding is 0).
                                        Layout.leftMargin: -Kirigami.Units.smallSpacing * 1.5
                                        onActiveFocusChanged: if (activeFocus && visualFocus) page.reveal(this)
                                        text: qsTr("How to fix it yourself")
                                        // One such button per finding: which one it is.
                                        Accessible.name: Util.fill(qsTr("How to fix it yourself: %1"), [card.f.title || ""])
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
                                        visible: card.manualOpen; text: card.f.manual || ""; flickable: flick
                                    }
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
            QQC2.Button { visible: page.fixable.length > 0; text: qsTr("Back"); icon.name: "go-previous"; onClicked: page.back() }
            PrimaryButton {
                id: mainButton
                text: page.fixable.length > 0 ? qsTr("Fix selected (%1)").arg(page.count) : qsTr("Back")
                icon.name: page.fixable.length > 0 ? "tools-wizard" : "go-previous"
                enabled: page.fixable.length === 0 || page.count > 0
                onClicked: page.primary()
            }
        }
    }
}
