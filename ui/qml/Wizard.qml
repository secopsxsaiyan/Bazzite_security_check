// Security Check - the setup wizard, a page of the main window: Welcome,
// Your PC, Options, Review. finished({use, fix, deep, report_dir, action})
// answers, with action "start" or "settings"; the root side of the tool
// validates it.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQuick.Dialogs
import org.kde.kirigami as Kirigami
import "util.js" as Util

Item {
    id: page
    required property var input
    property string iconSource: ""
    readonly property string title: qsTr("Security Check")
    signal finished(var answer)
    signal cancelled()

    readonly property var facts: input.facts || ({})
    readonly property var detected: input.detected || ({})
    property var answers: input.answers || ({})
    readonly property var steps: [qsTr("Welcome"), qsTr("Your PC"), qsTr("Options"), qsTr("Review")]
    readonly property int lastStep: steps.length - 1
    property int step: Math.max(0, Math.min(lastStep, Math.floor(Number(input.start_step) || 0)))
    // Below this width the step names do not fit next to each other.
    readonly property bool compact: width < Kirigami.Units.gridUnit * 38
    readonly property real sideMargin: Kirigami.Units.gridUnit
    readonly property real maxTextWidth: Kirigami.Units.gridUnit * 48
    // The width of a thin line or frame: one pixel, as Kirigami.Separator.
    readonly property int hairline: 1

    // What the band at the top says on each step.
    readonly property var headings: [
        [qsTr("Security check-up"), qsTr("For a home gaming and development PC. Checks updates, the firewall, network services, SSH, accounts, screen locking, secrets in your home folder, game streaming and more.")],
        [qsTr("How do you use this PC?"), qsTr("Turned on from what is installed. The checks adapt: services you use are reviewed, ones you don't are offered to be turned off.")],
        [qsTr("Options"), qsTr("All of these can be changed next time.")],
        [qsTr("Ready to check this PC"), qsTr("Nothing has been checked or changed yet.")]
    ]

    // How the PC is used: key, title, description, icon.
    readonly property var uses: [
        ["gaming", qsTr("Gaming"), qsTr("Steam, Lutris, Heroic and other launchers"), "input-gaming"],
        ["streaming", qsTr("Game streaming"), qsTr("Sunshine or Steam Remote Play to other devices"), "video-display"],
        ["dev", qsTr("Software development"), qsTr("Containers and local dev servers"), "utilities-terminal"],
        ["ssh", qsTr("Remote login (SSH)"), qsTr("Logging in to this PC from other devices"), "network-connect"],
        ["sharing", qsTr("Sharing files at home"), qsTr("Samba, Syncthing, KDE Connect"), "folder-network"],
        ["portable", qsTr("Leaves the house"), qsTr("A laptop or handheld on other networks"), "computer-laptop"]
    ]
    readonly property string useSummary: uses.filter(function (u) { return page.useOn(u[0]) })
                                             .map(function (u) { return u[1] }).join(", ") || qsTr("General desktop")

    function useOn(key) { return (answers.use || []).indexOf(key) >= 0 }
    function setUse(key, on) {
        var u = (answers.use || []).filter(function (k) { return k !== key })
        if (on) u.push(key)
        var a = Object.assign({}, answers); a.use = u; answers = a
    }
    function setAnswer(key, value) { var a = Object.assign({}, answers); a[key] = value; answers = a }
    function finish(action) {
        // The root side rejects an answer with a key missing, so fill them in.
        var a = Object.assign({}, answers)
        a.use = a.use || []
        a.fix = a.fix !== false
        a.deep = a.deep === true
        a.report_dir = a.report_dir || ""
        a.action = action
        page.finished(a)
    }
    // The root side rejects an answer without a report folder, whatever
    // the action: "Start the check" then goes to Options, where a message
    // asks for the folder, and "Settings" waits for it.
    readonly property bool hasFolder: !!answers.report_dir
    function primary() {
        if (step < lastStep) step++
        else if (!hasFolder) step = 2
        else finish("start")
    }
    // Esc is Back; on the first step it leaves the wizard.
    function dismiss() { if (step > 0) step--; else page.cancelled() }
    function initialFocus() { return mainButton }

    // A new step starts at its top.
    onStepChanged: {
        scroll.QQC2.ScrollBar.vertical.position = 0
        Qt.callLater(page.refocus)      // once the step's controls are shown
    }
    // The control with the keyboard focus may have gone with the step that
    // was left (Back, Settings, a Change button) or stopped being a button
    // (the step that is now the current one). A hidden control would still
    // take Space and Enter, so the focus moves to the main button, with a
    // focus ring when the control that had it was reached with the keyboard.
    function refocus() {
        var f = page.Window.activeFocusItem, inside = false
        for (var p = f; p && !inside; p = p.parent) inside = p === page
        if (!inside || (f.visible && f.enabled && f.focusPolicy !== Qt.NoFocus))
            return
        mainButton.forceActiveFocus(f.visualFocus ? Qt.TabFocusReason : Qt.OtherFocusReason)
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- step indicator: same band as the header under it ---------
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: stepRow.implicitHeight + Kirigami.Units.largeSpacing
            color: Kirigami.Theme.alternateBackgroundColor
            Kirigami.Theme.colorSet: Kirigami.Theme.Header
            Kirigami.Theme.inherit: false

            RowLayout {
                id: stepRow
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                anchors.leftMargin: page.sideMargin - Kirigami.Units.smallSpacing
                anchors.rightMargin: page.sideMargin
                spacing: 0
                Repeater {
                    model: page.steps
                    delegate: RowLayout {
                        id: stepItem
                        required property int index
                        required property string modelData
                        spacing: 0
                        // The line to the previous step shrinks first when space is short.
                        Layout.fillWidth: index > 0
                        Layout.maximumWidth: implicitWidth
                        Rectangle {
                            visible: stepItem.index > 0
                            Layout.fillWidth: true
                            Layout.minimumWidth: Kirigami.Units.smallSpacing
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                            Layout.leftMargin: Kirigami.Units.smallSpacing
                            Layout.rightMargin: Kirigami.Units.smallSpacing
                            implicitHeight: page.hairline
                            color: stepItem.index <= page.step ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor
                        }
                        StepButton { number: stepItem.index; name: stepItem.modelData }
                    }
                }
                Item { Layout.fillWidth: true }
            }
        }

        PageHeader {
            iconSource: page.iconSource
            title: page.headings[page.step][0]
            subtitle: page.headings[page.step][1]
        }

        // ---- the steps -------------------------------------------------
        QQC2.ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

            // Only the current step is visible, so only it takes up height.
            ColumnLayout {
                width: Math.min(scroll.availableWidth, page.maxTextWidth + page.sideMargin * 2)
                spacing: 0

                // 0: welcome
                ColumnLayout {
                    visible: page.step === 0
                    Layout.fillWidth: true
                    Layout.margins: page.sideMargin
                    spacing: Kirigami.Units.gridUnit

                    Kirigami.InlineMessage {
                        Layout.fillWidth: true
                        visible: true
                        type: Kirigami.MessageType.Positive
                        text: qsTr("<b>Nothing changes without your OK.</b> Every change is shown first and can be undone later.")
                    }
                    Section {
                        title: qsTr("This PC")
                        Card {
                            Layout.fillWidth: true
                            GridLayout {
                                anchors.left: parent.left; anchors.right: parent.right
                                columns: 2
                                columnSpacing: Kirigami.Units.gridUnit
                                rowSpacing: Kirigami.Units.smallSpacing
                                FactName { text: qsTr("System") }
                                FactValue { text: page.facts.os || qsTr("Unknown") }
                                FactName { text: qsTr("Image"); visible: !!page.facts.image }
                                FactValue { text: page.facts.image || ""; visible: !!page.facts.image }
                                FactName { text: qsTr("Hardware") }
                                FactValue { text: page.facts.hardware || qsTr("Unknown") }
                                FactName { text: qsTr("Disk") }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing
                                    Kirigami.Icon {
                                        visible: page.facts.disk === "yes" || page.facts.disk === "no"
                                        source: page.facts.disk === "yes" ? "object-locked" : "object-unlocked"
                                        implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth
                                        Accessible.ignored: true
                                    }
                                    FactValue {
                                        text: page.facts.disk === "yes" ? qsTr("Encrypted (LUKS)") : page.facts.disk === "no" ? qsTr("Not encrypted") : qsTr("Could not tell")
                                        color: page.facts.disk === "no" ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.textColor
                                    }
                                }
                                FactName { text: qsTr("Last check") }
                                FactValue { text: page.facts.last || qsTr("None yet") }
                            }
                        }
                    }
                    Section {
                        title: qsTr("What happens next")
                        NextLine { iconName: "preferences-system"; text: qsTr("You say how this PC is used and pick the options. It takes a minute.") }
                        NextLine { iconName: "security-high"; text: qsTr("The check runs and a dashboard shows the result of every check.") }
                        NextLine { iconName: "tools-wizard"; text: qsTr("You pick the fixes you want. Each one is shown and confirmed before it runs.") }
                    }
                }

                // 1: how the PC is used
                GridLayout {
                    visible: page.step === 1
                    Layout.fillWidth: true
                    Layout.margins: page.sideMargin
                    columns: page.width > Kirigami.Units.gridUnit * 40 ? 2 : 1
                    columnSpacing: Kirigami.Units.largeSpacing
                    rowSpacing: Kirigami.Units.largeSpacing
                    Repeater {
                        model: page.uses
                        delegate: OptionCard {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            // Equal columns, whatever the texts are.
                            Layout.preferredWidth: 1
                            title: modelData[1]; description: modelData[2]; iconName: modelData[3]
                            badge: page.detected[modelData[0]] ? qsTr("Detected") : ""
                            badgeTint: Kirigami.Theme.positiveTextColor
                            note: page.detected[modelData[0]] ? String(page.detected[modelData[0]]) : ""
                            switchedOn: page.useOn(modelData[0])
                            onSwitched: (on) => page.setUse(modelData[0], on)
                        }
                    }
                }

                // 2: options
                ColumnLayout {
                    visible: page.step === 2
                    Layout.fillWidth: true
                    Layout.margins: page.sideMargin
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.InlineMessage {
                        Layout.fillWidth: true
                        visible: !page.hasFolder
                        type: Kirigami.MessageType.Warning
                        text: qsTr("Choose a report folder below: the check cannot start without one.")
                    }
                    OptionCard {
                        Layout.fillWidth: true
                        title: qsTr("Offer fixes"); iconName: "tools-wizard"
                        badge: qsTr("Recommended"); badgeTint: Kirigami.Theme.positiveTextColor
                        description: qsTr("After the check, pick fixes from a list. Each one is shown and confirmed before it runs. Turn off for a report only.")
                        switchedOn: page.answers.fix !== false
                        onSwitched: (on) => page.setAnswer("fix", on)
                    }
                    OptionCard {
                        Layout.fillWidth: true
                        title: qsTr("Deep check"); iconName: "edit-find"
                        badge: qsTr("Several minutes"); badgeTint: Kirigami.Theme.neutralTextColor
                        description: qsTr("Also SUID files, autostart entries, changes to /etc and a ClamAV scan of Downloads.")
                        switchedOn: page.answers.deep === true
                        onSwitched: (on) => page.setAnswer("deep", on)
                    }
                    Card {
                        Layout.fillWidth: true
                        RowLayout {
                            anchors.left: parent.left; anchors.right: parent.right
                            spacing: Kirigami.Units.largeSpacing
                            Kirigami.Icon {
                                source: "folder-documents"
                                implicitWidth: Kirigami.Units.iconSizes.medium; implicitHeight: implicitWidth
                                Layout.alignment: Qt.AlignTop
                                Accessible.ignored: true
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing
                                Kirigami.Heading { text: qsTr("Report folder"); level: 4; Layout.fillWidth: true; wrapMode: Text.Wrap }
                                QQC2.Label {
                                    Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: Util.dimText
                                    text: qsTr("An HTML and a Markdown report are saved here after the check.")
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.topMargin: Kirigami.Units.smallSpacing
                                    spacing: Kirigami.Units.smallSpacing
                                    // Read-only: the folder is picked in the dialog, where it must exist.
                                    QQC2.TextField {
                                        id: reportField
                                        Layout.fillWidth: true
                                        // Without this a long path would set the width of the whole page.
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 10
                                        readOnly: true
                                        text: page.answers.report_dir || ""
                                        placeholderText: qsTr("No folder chosen")
                                        Accessible.name: qsTr("Report folder")
                                        QQC2.ToolTip.text: Util.tip(text)
                                        QQC2.ToolTip.visible: hovered && contentWidth > width - leftPadding - rightPadding
                                        QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                                        // Show the end of the path: that is the part that tells folders apart.
                                        onTextChanged: cursorPosition = text.length
                                        Component.onCompleted: cursorPosition = text.length
                                    }
                                    QQC2.Button {
                                        text: qsTr("Choose…")
                                        icon.name: "document-open-folder"
                                        Accessible.name: qsTr("Choose the report folder")
                                        onClicked: folderDialog.open()
                                    }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing
                                    Kirigami.Icon {
                                        source: "documentinfo"
                                        implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth
                                        Layout.alignment: Qt.AlignTop
                                        Accessible.ignored: true
                                    }
                                    QQC2.Label {
                                        Layout.fillWidth: true; wrapMode: Text.Wrap
                                        font: Kirigami.Theme.smallFont
                                        text: qsTr("Reports can contain host and user names. Review one before you share it.")
                                    }
                                }
                            }
                        }
                    }
                }

                // 3: review
                ColumnLayout {
                    visible: page.step === 3
                    Layout.fillWidth: true
                    Layout.margins: page.sideMargin
                    spacing: Kirigami.Units.largeSpacing

                    SummaryCard {
                        iconName: "computer"; name: qsTr("How this PC is used"); goTo: 1
                        value: page.useSummary
                    }
                    SummaryCard {
                        iconName: "edit-find"; name: qsTr("Depth"); goTo: 2
                        value: page.answers.deep === true ? qsTr("Deep check") : qsTr("Standard check")
                        detail: page.answers.deep === true ? qsTr("Takes several minutes.") : qsTr("Takes about a minute.")
                    }
                    SummaryCard {
                        iconName: "tools-wizard"; name: qsTr("Fixes"); goTo: 2
                        value: page.answers.fix === false ? qsTr("None, report only") : qsTr("Offered after the check")
                        detail: page.answers.fix === false ? qsTr("Nothing on this PC is changed.") : qsTr("You pick them, and each one is confirmed before it runs.")
                    }
                    SummaryCard {
                        iconName: "folder-documents"; name: qsTr("Report folder"); goTo: 2
                        value: page.answers.report_dir || qsTr("Not chosen")
                        wrapAnywhere: true
                        detail: page.answers.report_dir ? qsTr("An HTML and a Markdown report are saved here.")
                                                        : qsTr("Choose a folder before the check can start.")
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        Layout.topMargin: Kirigami.Units.smallSpacing
                        wrapMode: Text.Wrap; opacity: Util.dimText
                        text: qsTr("Your answers are remembered for next time. Afterwards a dashboard shows the result of every check.")
                    }
                }
            }
        }

        // ---- buttons ------------------------------------------------------
        FooterBar {
            leading: [
                // A switched-off button gets no pointer, so the reason is
                // shown by the item around it.
                Item {
                    visible: page.step === 0
                    implicitWidth: settingsButton.implicitWidth; implicitHeight: settingsButton.implicitHeight
                    QQC2.Button {
                        id: settingsButton
                        anchors.fill: parent
                        text: qsTr("Settings"); icon.name: "configure"
                        enabled: page.hasFolder
                        onClicked: page.finish("settings")
                        Accessible.description: enabled ? "" : settingsWhy.text
                    }
                    HoverHandler { id: settingsHover; enabled: !page.hasFolder }
                    QQC2.ToolTip {
                        id: settingsWhy
                        visible: settingsHover.hovered
                        delay: Kirigami.Units.toolTipDelay
                        text: qsTr("Choose a report folder first (under Options).")
                    }
                },
                QQC2.Button { text: qsTr("Quit"); icon.name: "application-exit"; onClicked: page.cancelled() }
            ]
            QQC2.Button { text: qsTr("Back"); icon.name: "go-previous"; visible: page.step > 0; onClicked: page.dismiss() }
            PrimaryButton {
                id: mainButton
                text: page.step === 0 ? qsTr("Get started") : page.step === page.lastStep ? qsTr("Start the check") : qsTr("Next")
                icon.name: page.step === page.lastStep ? "security-high" : "go-next"
                onClicked: page.primary()
            }
        }
    }

    FolderDialog {
        id: folderDialog
        // Each part encoded, so a "#" or "%" in a folder name stays part of the path.
        currentFolder: "file://" + String(page.answers.report_dir || "").split("/").map(encodeURIComponent).join("/")
        onAccepted: page.setAnswer("report_dir", decodeURIComponent(selectedFolder.toString().replace(/^file:\/\//, "")))
    }

    // One step in the indicator. A finished step is a button that goes back to it.
    component StepButton: QQC2.AbstractButton {
        id: stepButton
        property int number
        property string name
        readonly property bool done: number < page.step
        readonly property bool current: number === page.step

        padding: Kirigami.Units.smallSpacing
        // Not "enabled: done": a disabled item would get the greyed-out colours.
        focusPolicy: done ? Qt.StrongFocus : Qt.NoFocus
        // It stops being a button when its step is the current one, which
        // it cannot with the keyboard focus on it: that goes to the main
        // button first.
        onClicked: if (done) {
            if (activeFocus) mainButton.forceActiveFocus(visualFocus ? Qt.TabFocusReason : Qt.OtherFocusReason)
            page.step = number
        }
        Accessible.role: done ? Accessible.Button : Accessible.StaticText
        Accessible.name: done ? qsTr("Back to step %1 of %2: %3").arg(number + 1).arg(page.steps.length).arg(name)
                       : current ? qsTr("Step %1 of %2, current: %3").arg(number + 1).arg(page.steps.length).arg(name)
                       : qsTr("Step %1 of %2: %3").arg(number + 1).arg(page.steps.length).arg(name)
        QQC2.ToolTip.text: qsTr("Back to “%1”").arg(name)
        QQC2.ToolTip.visible: done && hovered
        QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
        HoverHandler { cursorShape: stepButton.done ? Qt.PointingHandCursor : Qt.ArrowCursor }

        contentItem: RowLayout {
            spacing: Kirigami.Units.smallSpacing
            Rectangle {
                implicitWidth: Kirigami.Units.gridUnit * 1.4; implicitHeight: implicitWidth; radius: width / 2
                color: stepButton.done ? Kirigami.Theme.positiveTextColor
                     : stepButton.current ? Kirigami.Theme.highlightColor : "transparent"
                border.color: stepButton.done || stepButton.current ? color : Kirigami.Theme.disabledTextColor
                border.width: page.hairline
                Kirigami.Icon {
                    anchors.centerIn: parent
                    width: parent.width * 0.7; height: width
                    visible: stepButton.done
                    source: "dialog-ok-apply"
                    color: Kirigami.Theme.highlightedTextColor
                    isMask: true
                }
                QQC2.Label {
                    anchors.centerIn: parent
                    visible: !stepButton.done
                    text: stepButton.number + 1
                    color: stepButton.current ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.disabledTextColor
                    font.bold: true
                }
            }
            QQC2.Label {
                // When narrow, only the current step keeps its name.
                visible: !page.compact || stepButton.current
                text: stepButton.name
                font.bold: stepButton.current
                font.underline: stepButton.done && (stepButton.hovered || stepButton.visualFocus)
                color: stepButton.done || stepButton.current ? Kirigami.Theme.textColor : Kirigami.Theme.disabledTextColor
            }
        }
        background: Rectangle {
            radius: Kirigami.Units.cornerRadius
            color: stepButton.done && stepButton.hovered ? Qt.alpha(Kirigami.Theme.highlightColor, 0.15) : "transparent"
            // Inside: the band it is on has no room around it.
            FocusRing { target: stepButton; cornerRadius: parent.radius; outset: 0; visible: stepButton.done && stepButton.visualFocus }
        }
    }

    // The frame around a card. Its content goes inside, as wide as the card.
    component Card: Rectangle {
        default property alias content: inner.data
        property real padding: Kirigami.Units.largeSpacing * 1.5
        implicitHeight: inner.childrenRect.height + padding * 2
        radius: Kirigami.Units.cornerRadius
        color: Kirigami.Theme.backgroundColor
        Kirigami.Theme.colorSet: Kirigami.Theme.View
        Kirigami.Theme.inherit: false
        border.width: page.hairline
        border.color: Kirigami.ColorUtils.linearInterpolation(Kirigami.Theme.backgroundColor, Kirigami.Theme.textColor, Kirigami.Theme.frameContrast)
        Item { id: inner; anchors.fill: parent; anchors.margins: parent.padding }
    }

    // Name and value of one fact about this PC. The values come from the PC.
    component FactName: QQC2.Label { opacity: Util.dimLabel; Layout.alignment: Qt.AlignTop }
    component FactValue: QQC2.Label { Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText }

    // One line of "what happens next".
    component NextLine: RowLayout {
        property alias iconName: nextIcon.source
        property alias text: nextText.text
        Layout.fillWidth: true
        spacing: Kirigami.Units.largeSpacing
        Kirigami.Icon {
            id: nextIcon
            implicitWidth: Kirigami.Units.iconSizes.smallMedium; implicitHeight: implicitWidth
            Layout.alignment: Qt.AlignTop
            Accessible.ignored: true
        }
        QQC2.Label { id: nextText; Layout.fillWidth: true; wrapMode: Text.Wrap }
    }

    // A card with an icon, a title, a description, an optional badge and a
    // switch. The whole card is the control, a check box: a click or Space
    // toggles it, and Enter is the page's main button as on any check box.
    // Switched on shows as a highlighted frame; the keyboard focus as a
    // ring around the card, so the two cannot be mixed up.
    component OptionCard: QQC2.AbstractButton {
        id: card
        property string title
        property string description
        property string iconName
        property string badge
        property color badgeTint: Kirigami.Theme.disabledTextColor
        property string note            // what was found on this PC (untrusted)
        property bool switchedOn
        signal switched(bool on)

        padding: Kirigami.Units.largeSpacing * 1.5
        focusPolicy: Qt.StrongFocus
        // Really a check box, also for a screen reader. A click or Space
        // replaces the binding of "checked", so it is put back.
        checkable: true
        checked: switchedOn
        onToggled: { card.switched(checked); checked = Qt.binding(function () { return card.switchedOn }) }
        Accessible.role: Accessible.CheckBox
        Accessible.name: card.badge !== "" ? qsTr("%1 (%2)").arg(card.title).arg(card.badge) : card.title
        Accessible.description: card.note !== "" ? qsTr("%1 Found on this PC: %2").arg(card.description).arg(card.note) : card.description
        Accessible.onToggleAction: card.switched(!card.switchedOn)
        Accessible.onPressAction: card.switched(!card.switchedOn)
        Kirigami.Theme.colorSet: Kirigami.Theme.View
        Kirigami.Theme.inherit: false

        contentItem: RowLayout {
            spacing: Kirigami.Units.largeSpacing
            Kirigami.Icon {
                source: card.iconName
                implicitWidth: Kirigami.Units.iconSizes.medium; implicitHeight: implicitWidth
                Layout.alignment: Qt.AlignTop
                Accessible.ignored: true
            }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                spacing: Kirigami.Units.smallSpacing
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    Kirigami.Heading {
                        text: card.title; level: 4; wrapMode: Text.Wrap
                        Layout.fillWidth: true
                        Layout.maximumWidth: Math.ceil(implicitWidth)
                    }
                    StatusChip { visible: card.badge !== ""; text: card.badge; tint: card.badgeTint; Accessible.ignored: true }
                    Item { Layout.fillWidth: true }
                }
                QQC2.Label { Layout.fillWidth: true; wrapMode: Text.Wrap; text: card.description; opacity: Util.dimText }
                QQC2.Label {
                    visible: card.note !== ""
                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    text: card.note
                    font: Kirigami.Theme.smallFont
                    color: Kirigami.Theme.positiveTextColor
                }
            }
            // The card around it takes the focus; a click or drag here still works.
            QQC2.Switch {
                checked: card.switchedOn
                // Toggling it replaces the binding above, so put it back.
                onToggled: { card.switched(checked); checked = Qt.binding(function () { return card.switchedOn }) }
                focusPolicy: Qt.NoFocus
                Layout.alignment: Qt.AlignVCenter
                Accessible.ignored: true
            }
        }
        background: Rectangle {
            radius: Kirigami.Units.cornerRadius
            color: card.down ? Qt.alpha(Kirigami.Theme.highlightColor, 0.2)
                 : card.hovered ? Qt.alpha(Kirigami.Theme.highlightColor, 0.1)
                 : Kirigami.Theme.backgroundColor
            border.width: page.hairline
            border.color: card.switchedOn ? Qt.alpha(Kirigami.Theme.highlightColor, 0.7)
                        : Kirigami.ColorUtils.linearInterpolation(Kirigami.Theme.backgroundColor, Kirigami.Theme.textColor, Kirigami.Theme.frameContrast)
            FocusRing { target: card; cornerRadius: parent.radius }
        }
    }

    // One choice on the review step, with a link back to the step it was made on.
    component SummaryCard: Card {
        id: summary
        property string iconName
        property string name
        property string value
        property string detail
        property int goTo
        property bool wrapAnywhere: false   // the value is a path: break it anywhere
        Layout.fillWidth: true
        RowLayout {
            anchors.left: parent.left; anchors.right: parent.right
            spacing: Kirigami.Units.largeSpacing
            Kirigami.Icon {
                source: summary.iconName
                implicitWidth: Kirigami.Units.iconSizes.medium; implicitHeight: implicitWidth
                Layout.alignment: Qt.AlignTop
                Accessible.ignored: true
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                QQC2.Label { text: summary.name; font: Kirigami.Theme.smallFont; opacity: Util.dimLabel; Layout.fillWidth: true; elide: Text.ElideRight }
                QQC2.Label {
                    Layout.fillWidth: true
                    text: summary.value
                    textFormat: Text.PlainText
                    font.weight: Font.DemiBold
                    wrapMode: summary.wrapAnywhere ? Text.WrapAnywhere : Text.Wrap
                    maximumLineCount: 4; elide: Text.ElideRight
                }
                QQC2.Label {
                    visible: summary.detail !== ""
                    Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: Util.dimText
                    text: summary.detail
                }
            }
            QQC2.Button {
                text: qsTr("Change")
                icon.name: "document-edit"
                flat: true
                Layout.alignment: Qt.AlignVCenter
                Accessible.name: qsTr("Change: %1").arg(summary.name)
                onClicked: page.step = summary.goTo
            }
        }
    }
}
