// Security Check - setup wizard (Kirigami). Answers go back through
// bridge.finish(); the root side of the tool validates them.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQuick.Dialogs
import org.kde.kirigami as Kirigami

Kirigami.ApplicationWindow {
    id: root
    title: "Security Check"
    width: Kirigami.Units.gridUnit * 44
    height: Kirigami.Units.gridUnit * 34
    minimumWidth: Kirigami.Units.gridUnit * 30
    minimumHeight: Kirigami.Units.gridUnit * 26
    pageStack.globalToolBar.style: Kirigami.ApplicationHeaderStyle.None

    readonly property var input: bridge.input
    readonly property var facts: input.facts || ({})
    readonly property var detected: input.detected || ({})
    property var answers: input.answers || ({})
    readonly property var steps: ["Welcome", "Your PC", "Options", "Report", "Review"]
    property int step: Math.max(0, Math.min(4, input.start_step || 0))

    // How the PC is used: key, title, description, icon.
    readonly property var uses: [
        ["gaming", "Gaming", "Steam, Lutris, Heroic and other launchers", "input-gaming"],
        ["streaming", "Game streaming", "Sunshine or Steam Remote Play to other devices", "video-display"],
        ["dev", "Software development", "Containers and local dev servers", "utilities-terminal"],
        ["ssh", "Remote login (SSH)", "Logging in to this PC from other devices", "network-connect"],
        ["sharing", "Sharing files at home", "Samba, Syncthing, KDE Connect", "folder-network"],
        ["portable", "Leaves the house", "A laptop or handheld on other networks", "computer-laptop"]
    ]

    function useOn(key) { return (answers.use || []).indexOf(key) >= 0 }
    function setUse(key, on) {
        var u = (answers.use || []).filter(function (k) { return k !== key })
        if (on) u.push(key)
        var a = Object.assign({}, answers); a.use = u; answers = a
    }
    function setAnswer(key, value) { var a = Object.assign({}, answers); a[key] = value; answers = a }
    function finish(action) {
        var a = Object.assign({}, answers); a.action = action
        bridge.finish(a)
    }

    onClosing: bridge.cancel()

    pageStack.initialPage: Kirigami.Page {
        padding: 0
        titleDelegate: Item {}

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // ---- step indicator ----------------------------------------
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: stepRow.implicitHeight + Kirigami.Units.largeSpacing * 2
                color: Kirigami.Theme.alternateBackgroundColor
                Kirigami.Theme.colorSet: Kirigami.Theme.Header
                Kirigami.Theme.inherit: false

                RowLayout {
                    id: stepRow
                    anchors.centerIn: parent
                    spacing: Kirigami.Units.smallSpacing
                    Repeater {
                        model: root.steps
                        delegate: RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            Rectangle {
                                width: Kirigami.Units.gridUnit * 1.4; height: width; radius: width / 2
                                color: index < root.step ? Kirigami.Theme.positiveTextColor
                                     : index === root.step ? Kirigami.Theme.highlightColor
                                     : "transparent"
                                border.color: index <= root.step ? color : Kirigami.Theme.disabledTextColor
                                border.width: 1
                                Kirigami.Icon {
                                    anchors.centerIn: parent
                                    width: parent.width * 0.7; height: width
                                    visible: index < root.step
                                    source: "dialog-ok-apply"
                                    color: Kirigami.Theme.highlightedTextColor
                                    isMask: true
                                }
                                QQC2.Label {
                                    anchors.centerIn: parent
                                    visible: index >= root.step
                                    text: index + 1
                                    color: index === root.step ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.disabledTextColor
                                    font.bold: true
                                }
                            }
                            QQC2.Label {
                                text: modelData
                                font.bold: index === root.step
                                color: index <= root.step ? Kirigami.Theme.textColor : Kirigami.Theme.disabledTextColor
                            }
                            Rectangle {
                                visible: index < root.steps.length - 1
                                implicitWidth: Kirigami.Units.gridUnit * 1.5; implicitHeight: 1
                                color: Kirigami.Theme.disabledTextColor
                                Layout.leftMargin: Kirigami.Units.smallSpacing
                                Layout.rightMargin: Kirigami.Units.smallSpacing
                            }
                        }
                    }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            // ---- pages --------------------------------------------------
            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: availableWidth
                clip: true

                StackLayout {
                    id: pages
                    width: parent.width
                    currentIndex: root.step

                    // 0: welcome
                    ColumnLayout {
                        spacing: Kirigami.Units.largeSpacing
                        Item { implicitHeight: Kirigami.Units.largeSpacing }
                        RowLayout {
                            Layout.leftMargin: Kirigami.Units.gridUnit * 2
                            Layout.rightMargin: Kirigami.Units.gridUnit * 2
                            spacing: Kirigami.Units.gridUnit
                            Kirigami.Icon {
                                source: bridge.iconSource
                                implicitWidth: Kirigami.Units.iconSizes.enormous
                                implicitHeight: implicitWidth
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                Kirigami.Heading { text: "Security check-up"; level: 1 }
                                QQC2.Label {
                                    Layout.fillWidth: true; wrapMode: Text.Wrap
                                    opacity: 0.8
                                    text: "For a home gaming and development PC. Checks updates, the firewall, network services, SSH, accounts, screen locking, secrets in your home folder, game streaming and more."
                                }
                            }
                        }
                        Kirigami.InlineMessage {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 2
                            Layout.rightMargin: Kirigami.Units.gridUnit * 2
                            visible: true
                            type: Kirigami.MessageType.Positive
                            text: "<b>Nothing changes without your OK.</b> Every change is shown first and can be undone later."
                        }
                        Kirigami.FormLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 2
                            Kirigami.Separator { Kirigami.FormData.label: "This PC"; Kirigami.FormData.isSection: true }
                            QQC2.Label { Kirigami.FormData.label: "System:"; text: root.facts.os || "unknown" }
                            QQC2.Label { Kirigami.FormData.label: "Image:"; text: root.facts.image || "-"; visible: !!root.facts.image }
                            QQC2.Label { Kirigami.FormData.label: "Hardware:"; text: root.facts.hardware || "-" }
                            QQC2.Label {
                                Kirigami.FormData.label: "Disk:"
                                text: root.facts.disk === "yes" ? "Encrypted (LUKS)" : root.facts.disk === "no" ? "Not encrypted" : "Could not tell"
                                color: root.facts.disk === "no" ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.textColor
                            }
                            QQC2.Label {
                                Kirigami.FormData.label: "Last check:"
                                text: root.facts.last || "None yet"
                            }
                        }
                    }

                    // 1: how the PC is used
                    ColumnLayout {
                        spacing: Kirigami.Units.largeSpacing
                        PageTitle { title: "How do you use this PC?"; subtitle: "Turned on from what is installed. The checks adapt: services you use are reviewed, ones you don't are offered to be turned off." }
                        GridLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 2
                            Layout.rightMargin: Kirigami.Units.gridUnit * 2
                            columns: root.width > Kirigami.Units.gridUnit * 36 ? 2 : 1
                            columnSpacing: Kirigami.Units.largeSpacing
                            rowSpacing: Kirigami.Units.largeSpacing
                            Repeater {
                                model: root.uses
                                delegate: OptionCard {
                                    Layout.fillWidth: true
                                    title: modelData[1]; description: modelData[2]; iconName: modelData[3]
                                    badge: root.detected[modelData[0]] ? "Detected" : ""
                                    badgeTip: root.detected[modelData[0]] || ""
                                    switchedOn: root.useOn(modelData[0])
                                    onSwitched: (on) => root.setUse(modelData[0], on)
                                }
                            }
                        }
                    }

                    // 2: options
                    ColumnLayout {
                        spacing: Kirigami.Units.largeSpacing
                        PageTitle { title: "Options"; subtitle: "Both can be changed next time." }
                        OptionCard {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 2
                            Layout.rightMargin: Kirigami.Units.gridUnit * 2
                            title: "Offer fixes"; iconName: "tools-wizard"; badge: "Recommended"
                            description: "After the check, pick fixes from a list. Each one is shown and confirmed before it runs. Turn off for a report only."
                            switchedOn: root.answers.fix !== false
                            onSwitched: (on) => root.setAnswer("fix", on)
                        }
                        OptionCard {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 2
                            Layout.rightMargin: Kirigami.Units.gridUnit * 2
                            title: "Deep check"; iconName: "edit-find"; badge: "Several minutes"
                            description: "Also SUID files, autostart entries, changes to /etc and a ClamAV scan of Downloads."
                            switchedOn: root.answers.deep === true
                            onSwitched: (on) => root.setAnswer("deep", on)
                        }
                    }

                    // 3: report
                    ColumnLayout {
                        spacing: Kirigami.Units.largeSpacing
                        PageTitle { title: "Report"; subtitle: "An HTML and a Markdown report are saved after the check." }
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 2
                            Layout.rightMargin: Kirigami.Units.gridUnit * 2
                            Kirigami.Icon { source: "folder-documents"; implicitWidth: Kirigami.Units.iconSizes.medium; implicitHeight: implicitWidth }
                            QQC2.TextField { Layout.fillWidth: true; readOnly: true; text: root.answers.report_dir || "" }
                            QQC2.Button { text: "Choose…"; icon.name: "document-open-folder"; onClicked: folderDialog.open() }
                        }
                        Kirigami.InlineMessage {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 2
                            Layout.rightMargin: Kirigami.Units.gridUnit * 2
                            visible: true
                            type: Kirigami.MessageType.Information
                            text: "Reports can contain host and user names. Review one before you share it."
                        }
                    }

                    // 4: review
                    ColumnLayout {
                        spacing: Kirigami.Units.largeSpacing
                        PageTitle { title: "Ready to check this PC"; subtitle: "Nothing has been checked or changed yet." }
                        Kirigami.FormLayout {
                            Layout.fillWidth: true
                            QQC2.Label {
                                Kirigami.FormData.label: "Use:"
                                text: root.uses.filter(function (u) { return root.useOn(u[0]) }).map(function (u) { return u[1] }).join(", ") || "General desktop"
                                wrapMode: Text.Wrap
                                Layout.maximumWidth: Kirigami.Units.gridUnit * 24
                            }
                            QQC2.Label { Kirigami.FormData.label: "Depth:"; text: root.answers.deep ? "Deep · several minutes" : "Standard · about a minute" }
                            QQC2.Label { Kirigami.FormData.label: "Fixes:"; text: root.answers.fix === false ? "None - report only" : "Offered after the check, each confirmed" }
                            QQC2.Label { Kirigami.FormData.label: "Report:"; text: root.answers.report_dir || "-"; elide: Text.ElideMiddle; Layout.maximumWidth: Kirigami.Units.gridUnit * 24 }
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 2
                            Layout.rightMargin: Kirigami.Units.gridUnit * 2
                            wrapMode: Text.Wrap; opacity: 0.8
                            text: "Your answers are remembered for next time. Afterwards a dashboard shows the result of every check."
                        }
                    }
                }
            }

            // ---- buttons ------------------------------------------------
            Kirigami.Separator { Layout.fillWidth: true }
            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                QQC2.Button { text: "Settings"; icon.name: "configure"; visible: root.step === 0; onClicked: root.finish("settings") }
                QQC2.Button { text: "Quit"; icon.name: "application-exit"; flat: true; onClicked: bridge.cancel() }
                Item { Layout.fillWidth: true }
                QQC2.Button { text: "Back"; icon.name: "go-previous"; visible: root.step > 0; onClicked: root.step-- }
                QQC2.Button {
                    text: root.step === 0 ? "Get started" : root.step === root.steps.length - 1 ? "Start the check" : "Next"
                    icon.name: root.step === root.steps.length - 1 ? "security-high" : "go-next"
                    highlighted: true
                    font.bold: true
                    onClicked: root.step === root.steps.length - 1 ? root.finish("start") : root.step++
                }
            }
        }
    }

    FolderDialog {
        id: folderDialog
        currentFolder: "file://" + (root.answers.report_dir || "")
        onAccepted: root.setAnswer("report_dir", decodeURIComponent(selectedFolder.toString().replace(/^file:\/\//, "")))
    }

    // A page heading with a one-line explanation under it.
    component PageTitle: ColumnLayout {
        property alias title: heading.text
        property alias subtitle: sub.text
        Layout.fillWidth: true
        Layout.topMargin: Kirigami.Units.gridUnit
        Layout.leftMargin: Kirigami.Units.gridUnit * 2
        Layout.rightMargin: Kirigami.Units.gridUnit * 2
        spacing: Kirigami.Units.smallSpacing
        Kirigami.Heading { id: heading; level: 1; Layout.fillWidth: true; wrapMode: Text.Wrap }
        QQC2.Label { id: sub; Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.8 }
    }

    // A card with an icon, a title, a description, an optional badge and a switch.
    component OptionCard: Kirigami.AbstractCard {
        id: card
        property string title
        property string description
        property string iconName
        property string badge
        property string badgeTip
        property bool switchedOn
        signal switched(bool on)
        showClickFeedback: true
        onClicked: card.switched(!card.switchedOn)
        contentItem: RowLayout {
            spacing: Kirigami.Units.largeSpacing
            Kirigami.Icon { source: card.iconName; implicitWidth: Kirigami.Units.iconSizes.medium; implicitHeight: implicitWidth; Layout.alignment: Qt.AlignTop }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                RowLayout {
                    Kirigami.Heading { text: card.title; level: 4 }
                    Kirigami.Chip {
                        visible: card.badge !== ""
                        text: card.badge
                        closable: false; checkable: false
                        QQC2.ToolTip.text: card.badgeTip
                        QQC2.ToolTip.visible: hovered && card.badgeTip !== ""
                    }
                }
                QQC2.Label { Layout.fillWidth: true; wrapMode: Text.Wrap; text: card.description; opacity: 0.8 }
                QQC2.Label {
                    visible: card.badgeTip !== ""
                    Layout.fillWidth: true; wrapMode: Text.Wrap
                    text: "Detected: " + card.badgeTip
                    font: Kirigami.Theme.smallFont
                    color: Kirigami.Theme.positiveTextColor
                }
            }
            QQC2.Switch {
                checked: card.switchedOn
                onToggled: card.switched(checked)
                Accessible.name: card.title
            }
        }
    }
}
