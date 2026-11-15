// Security Check - settings, a page of the main window. finished({action,
// theme, update_check}) answers, with action "save" or "update"; the root
// side validates it. The release check runs here, as
// the desktop user; installing an update is done by the root side of the
// tool, which verifies the release's signature and checksums first.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

Item {
    id: page
    required property var input
    property string iconSource: ""
    readonly property string title: qsTr("Settings")
    signal finished(var answer)
    signal cancelled()

    readonly property string version: input.version || "0"
    readonly property string repo: input.repo || ""
    // Only a real "owner/name" is asked about or linked to.
    readonly property bool repoOk: /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)
    // Anything but a known theme counts as "system", as the combo box shows it.
    property string theme: ["light", "dark"].indexOf(input.theme) >= 0 ? input.theme : "system"
    property bool updateCheck: input.update_check === true || input.update_check === "1"
    property string latest: ""
    property string latestNotes: ""
    property string checkState: "idle"      // idle | checking | done | error
    readonly property bool updateAvailable: checkState === "done" && newer(latest, version)
    readonly property real maxTextWidth: Kirigami.Units.gridUnit * 48

    // a > b for "1.2.3"-style versions
    function newer(a, b) {
        var x = a.replace(/^v/, "").split("."), y = b.replace(/^v/, "").split(".")
        for (var i = 0; i < Math.max(x.length, y.length); i++) {
            var p = parseInt(x[i] || "0"), q = parseInt(y[i] || "0")
            if (p !== q) return p > q
        }
        return false
    }
    function check() {
        if (!repoOk) { checkState = "error"; return }
        checkState = "checking"
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            try {
                var r = JSON.parse(xhr.responseText)
                if (xhr.status !== 200 || !/^v?[0-9]+(\.[0-9]+)*$/.test(r.tag_name)) throw "bad"
                latest = r.tag_name.replace(/^v/, "")
                latestNotes = (r.body || "").substring(0, 1200)
                checkState = "done"
            } catch (e) { checkState = "error" }
        }
        xhr.open("GET", "https://api.github.com/repos/" + repo + "/releases/latest")
        xhr.setRequestHeader("Accept", "application/vnd.github+json")
        xhr.send()
    }
    function save(action) {
        page.finished({ "action": action, "theme": theme, "update_check": updateCheck })
    }
    function primary() { save("save") }
    function dismiss() { page.cancelled() }
    function initialFocus() { return mainButton }

    Component.onCompleted: if (input.check_now) check()

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        PageHeader {
            iconSource: page.iconSource
            title: qsTr("Settings")
            subtitle: qsTr("Security Check %1").arg(page.version)
        }

        QQC2.ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

            ColumnLayout {
                width: Math.min(scroll.availableWidth, page.maxTextWidth + Kirigami.Units.gridUnit * 2)
                spacing: 0

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.gridUnit
                    spacing: Kirigami.Units.gridUnit * 1.25

                    // ---- appearance ------------------------------------
                    Section {
                        title: qsTr("Appearance")
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.largeSpacing
                            QQC2.Label { text: qsTr("Theme:") }
                            QQC2.ComboBox {
                                Layout.minimumWidth: Kirigami.Units.gridUnit * 12
                                textRole: "text"; valueRole: "value"
                                model: [
                                    { text: qsTr("Follow the system"), value: "system" },
                                    { text: qsTr("Light"), value: "light" },
                                    { text: qsTr("Dark"), value: "dark" }
                                ]
                                Accessible.name: qsTr("Theme")
                                Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.theme))
                                onActivated: page.theme = currentValue
                            }
                            Item { Layout.fillWidth: true }
                        }
                        Hint { text: qsTr("Applied as soon as you save.") }
                    }

                    Kirigami.Separator { Layout.fillWidth: true }

                    // ---- updates ---------------------------------------
                    Section {
                        title: qsTr("Updates")
                        GridLayout {
                            Layout.fillWidth: true
                            columns: 2
                            columnSpacing: Kirigami.Units.largeSpacing
                            rowSpacing: Kirigami.Units.smallSpacing
                            QQC2.Label { text: qsTr("Installed version:"); opacity: Util.dimText }
                            QQC2.Label { Layout.fillWidth: true; text: page.version; textFormat: Text.PlainText; elide: Text.ElideRight }
                            QQC2.Label { text: qsTr("Latest release:"); opacity: Util.dimText; Layout.alignment: Qt.AlignTop }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing
                                QQC2.BusyIndicator {
                                    visible: page.checkState === "checking"; running: visible
                                    implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth
                                    Accessible.ignored: true
                                }
                                Kirigami.Icon {
                                    visible: page.checkState === "done" || page.checkState === "error"
                                    source: page.checkState === "error" ? "dialog-error" : page.updateAvailable ? "update-none" : "dialog-ok-apply"
                                    implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth
                                    Layout.alignment: Qt.AlignTop
                                    Accessible.ignored: true
                                }
                                QQC2.Label {
                                    Layout.fillWidth: true
                                    wrapMode: Text.Wrap; textFormat: Text.PlainText
                                    text: page.checkState === "idle" ? qsTr("Not checked yet")
                                        : page.checkState === "checking" ? qsTr("Checking…")
                                        : page.checkState === "error" ? qsTr("Could not reach GitHub")
                                        : page.updateAvailable ? qsTr("%1 - an update is available").arg(page.latest)
                                        : qsTr("%1 - you have the latest version").arg(page.latest)
                                    color: page.updateAvailable ? Kirigami.Theme.positiveTextColor
                                         : page.checkState === "error" ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                                    Accessible.name: qsTr("Latest release: %1").arg(text)
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing
                            QQC2.Button {
                                text: qsTr("Check now"); icon.name: "view-refresh"
                                enabled: page.checkState !== "checking"
                                onClicked: page.check()
                            }
                            // Saves the settings too, then the root side installs the update.
                            QQC2.Button {
                                text: qsTr("Install update…")
                                icon.name: "update-none"
                                visible: page.updateAvailable
                                onClicked: page.save("update")
                            }
                            Item { Layout.fillWidth: true }
                        }
                        // What is new in the release. The text comes from GitHub: plain text only.
                        Rectangle {
                            visible: page.updateAvailable && page.latestNotes !== ""
                            Layout.fillWidth: true
                            Layout.topMargin: Kirigami.Units.smallSpacing
                            implicitHeight: notes.implicitHeight + Kirigami.Units.largeSpacing * 2
                            radius: Kirigami.Units.cornerRadius
                            Kirigami.Theme.colorSet: Kirigami.Theme.View
                            Kirigami.Theme.inherit: false
                            color: Kirigami.Theme.backgroundColor
                            border.width: 1
                            border.color: Kirigami.ColorUtils.linearInterpolation(Kirigami.Theme.backgroundColor, Kirigami.Theme.textColor, Kirigami.Theme.frameContrast)
                            ColumnLayout {
                                id: notes
                                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                                anchors.margins: Kirigami.Units.largeSpacing
                                spacing: Kirigami.Units.smallSpacing
                                QQC2.Label {
                                    Layout.fillWidth: true; elide: Text.ElideRight
                                    font.weight: Font.DemiBold; textFormat: Text.PlainText
                                    text: qsTr("New in %1").arg(page.latest)
                                }
                                QQC2.Label {
                                    Layout.fillWidth: true
                                    text: page.latestNotes
                                    textFormat: Text.PlainText
                                    wrapMode: Text.Wrap; opacity: Util.dimSentence
                                }
                            }
                        }
                        QQC2.CheckBox {
                            Layout.fillWidth: true
                            Layout.topMargin: Kirigami.Units.smallSpacing
                            text: qsTr("Check for updates when Security Check starts")
                            checked: page.updateCheck
                            onToggled: page.updateCheck = checked
                        }
                        Hint { text: qsTr("Updates are downloaded from GitHub and installed only after their signature and checksums are verified.") }
                    }

                    Kirigami.Separator { Layout.fillWidth: true }

                    // ---- about -----------------------------------------
                    Section {
                        title: qsTr("About")
                        QQC2.Label {
                            Layout.fillWidth: true; wrapMode: Text.Wrap
                            text: qsTr("A security check-up for Bazzite gaming and development PCs.")
                        }
                        Hint { text: qsTr("License: GPL-3.0") }
                        Kirigami.UrlButton {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignLeft
                            elide: Text.ElideMiddle
                            url: "https://github.com/" + page.repo
                            // Only a link to a real "owner/name" repository is offered.
                            visible: page.repoOk
                            activeFocusOnTab: visible
                            Accessible.name: qsTr("Project page: %1").arg(url)
                        }
                    }
                }
            }
        }

        FooterBar {
            QQC2.Button { text: qsTr("Cancel"); icon.name: "dialog-cancel"; onClicked: page.dismiss() }
            PrimaryButton { id: mainButton; text: qsTr("Save"); icon.name: "document-save"; onClicked: page.primary() }
        }
    }

    // A dimmed line that explains the control above it.
    component Hint: QQC2.Label {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        opacity: Util.dimQuiet
    }
}
