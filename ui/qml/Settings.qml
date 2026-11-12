// Security Check - settings (Kirigami). The release check runs here, as
// the desktop user; installing an update is done by the root side of the
// tool, which verifies the release's signature and checksums first.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.ApplicationWindow {
    id: root
    title: "Security Check - Settings"
    width: Kirigami.Units.gridUnit * 42
    height: Kirigami.Units.gridUnit * 34
    minimumWidth: Kirigami.Units.gridUnit * 26
    minimumHeight: Kirigami.Units.gridUnit * 22
    pageStack.globalToolBar.style: Kirigami.ApplicationHeaderStyle.None

    readonly property var input: bridge.input
    readonly property string version: input.version || "0"
    readonly property string repo: input.repo || ""
    property string theme: input.theme || "system"
    property bool updateCheck: input.update_check === true || input.update_check === "1"
    property string latest: ""
    property string latestNotes: ""
    property string checkState: "idle"      // idle | checking | done | error

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
        if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) { checkState = "error"; return }
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
        bridge.finish({ "action": action, "theme": theme, "update_check": updateCheck })
    }

    onClosing: bridge.cancel()
    Component.onCompleted: if (input.check_now) check()

    pageStack.initialPage: Kirigami.ScrollablePage {
        titleDelegate: Item {}

        Kirigami.FormLayout {
            Kirigami.Separator { Kirigami.FormData.label: "Appearance"; Kirigami.FormData.isSection: true }
            QQC2.ComboBox {
                Kirigami.FormData.label: "Theme:"
                textRole: "text"; valueRole: "value"
                model: [
                    { text: "Follow the system", value: "system" },
                    { text: "Light", value: "light" },
                    { text: "Dark", value: "dark" }
                ]
                Component.onCompleted: currentIndex = indexOfValue(root.theme)
                onActivated: root.theme = currentValue
            }
            QQC2.Label {
                text: "Used by Security Check's windows from the next one you open."
                opacity: 0.7; wrapMode: Text.Wrap
                Layout.maximumWidth: Kirigami.Units.gridUnit * 18
            }

            Kirigami.Separator { Kirigami.FormData.label: "Updates"; Kirigami.FormData.isSection: true }
            QQC2.Label { Kirigami.FormData.label: "Installed version:"; text: root.version }
            RowLayout {
                Kirigami.FormData.label: "Latest release:"
                QQC2.BusyIndicator { visible: root.checkState === "checking"; running: visible; implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth }
                QQC2.Label {
                    text: root.checkState === "idle" ? "Not checked yet"
                        : root.checkState === "checking" ? "Checking…"
                        : root.checkState === "error" ? "Could not reach GitHub"
                        : root.newer(root.latest, root.version) ? root.latest + " - an update is available"
                        : root.latest + " - you have the latest version"
                    color: root.checkState === "done" && root.newer(root.latest, root.version) ? Kirigami.Theme.positiveTextColor
                         : root.checkState === "error" ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                }
            }
            RowLayout {
                QQC2.Button { text: "Check now"; icon.name: "view-refresh"; enabled: root.checkState !== "checking"; onClicked: root.check() }
                QQC2.Button {
                    text: "Install update…"
                    icon.name: "update-none"
                    highlighted: true
                    visible: root.checkState === "done" && root.newer(root.latest, root.version)
                    onClicked: root.save("update")
                }
            }
            QQC2.Label {
                visible: root.latestNotes !== "" && root.newer(root.latest, root.version)
                text: root.latestNotes
                textFormat: Text.PlainText
                wrapMode: Text.Wrap; opacity: 0.85
                Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            }
            QQC2.Label {
                text: "Updates are downloaded from GitHub and installed only after their signature and checksums are verified."
                opacity: 0.7; wrapMode: Text.Wrap
                Layout.maximumWidth: Kirigami.Units.gridUnit * 18
            }
            QQC2.CheckBox {
                text: "Check for updates when Security Check starts"
                checked: root.updateCheck
                onToggled: root.updateCheck = checked
            }

            Kirigami.Separator { Kirigami.FormData.label: "About"; Kirigami.FormData.isSection: true }
            RowLayout {
                Kirigami.Icon { source: bridge.iconSource; implicitWidth: Kirigami.Units.iconSizes.large; implicitHeight: implicitWidth }
                ColumnLayout {
                    Kirigami.Heading { text: "Security Check " + root.version; level: 3 }
                    QQC2.Label { text: "A security check-up for Bazzite gaming and development PCs. GPL-3.0."; opacity: 0.8 }
                    Kirigami.UrlButton { url: "https://github.com/" + root.repo; visible: root.repo !== "" }
                }
            }
        }

        footer: QQC2.DialogButtonBox {
            standardButtons: QQC2.DialogButtonBox.Save | QQC2.DialogButtonBox.Cancel
            onAccepted: root.save("save")
            onRejected: bridge.cancel()
        }
    }
}
