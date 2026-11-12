// Security Check - choose items (Kirigami), in the wizard's style: the apps,
// ports, packages or problems a fix may change. Each item can be ticked on
// its own, with its risk and what could break; Select all / none (and "low
// risk only" when items are graded) set them at once.
// bridge.finish({tags: [...]}) answers; the root side keeps only tags it
// offered.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.ApplicationWindow {
    id: root
    title: "Security Check"
    width: Kirigami.Units.gridUnit * 46
    height: Kirigami.Units.gridUnit * 38
    minimumWidth: Kirigami.Units.gridUnit * 30
    minimumHeight: Kirigami.Units.gridUnit * 24
    pageStack.globalToolBar.style: Kirigami.ApplicationHeaderStyle.None

    readonly property var d: bridge.input
    readonly property var items: d.items || []
    readonly property bool graded: items.some(function (i) { return !!i.risk })
    property var picked: items.map(function (i) { return i.on === true })
    readonly property int count: picked.filter(function (p) { return p }).length

    function riskColor(r) {
        return r === "high" ? Kirigami.Theme.negativeTextColor
             : r === "medium" ? Kirigami.Theme.neutralTextColor
             : r === "low" ? Kirigami.Theme.positiveTextColor
             : Kirigami.Theme.disabledTextColor
    }
    function riskText(r) {
        return r === "high" ? "High risk" : r === "medium" ? "Medium risk" : r === "low" ? "Low risk" : r
    }
    function setAll(f) { picked = items.map(function (i, n) { return f(i, n) }) }
    function toggle(n, v) { var p = picked.slice(); p[n] = v; picked = p }
    function done() {
        var t = []
        for (var n = 0; n < items.length; n++) if (picked[n]) t.push(items[n].tag)
        bridge.finish({ "tags": t })
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
                        source: bridge.iconSource
                        Layout.alignment: Qt.AlignTop
                        implicitWidth: Kirigami.Units.iconSizes.huge; implicitHeight: implicitWidth
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Heading { text: root.d.title || "Choose"; level: 1; textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        QQC2.Label {
                            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                            visible: text !== ""
                            text: root.d.intro || ""
                        }
                    }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            // ---- select all / none / low risk ------------------------------
            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                Layout.leftMargin: Kirigami.Units.gridUnit; Layout.rightMargin: Kirigami.Units.gridUnit
                spacing: Kirigami.Units.smallSpacing
                QQC2.Button { text: "Select all"; icon.name: "edit-select-all"; onClicked: root.setAll(function () { return true }) }
                QQC2.Button { text: "Select none"; icon.name: "edit-select-none"; onClicked: root.setAll(function () { return false }) }
                QQC2.Button {
                    // Not where a tick keeps something (the firewall list):
                    // there, unticking is the risky part.
                    visible: root.graded && root.d.low_only !== false && root.items.some(function (i) { return i.risk === "low" })
                    text: "Low risk only"; icon.name: "security-high"
                    onClicked: root.setAll(function (i) { return i.risk === "low" })
                }
                Item { Layout.fillWidth: true }
                QQC2.Label { text: root.count + " of " + root.items.length + " selected"; opacity: 0.75 }
            }

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: availableWidth
                clip: true

                ColumnLayout {
                    width: parent.width
                    spacing: Kirigami.Units.smallSpacing

                    Repeater {
                        model: root.items
                        delegate: Rectangle {
                            id: row
                            required property var modelData
                            required property int index
                            readonly property bool on: root.picked[index] === true
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit; Layout.rightMargin: Kirigami.Units.gridUnit
                            implicitHeight: body.implicitHeight + Kirigami.Units.largeSpacing * 2
                            radius: Kirigami.Units.cornerRadius
                            color: on ? Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g, Kirigami.Theme.highlightColor.b, 0.10)
                                      : Kirigami.Theme.backgroundColor
                            border.color: on ? Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g, Kirigami.Theme.highlightColor.b, 0.6)
                                             : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)

                            MouseArea { anchors.fill: parent; onClicked: root.toggle(row.index, !row.on) }

                            RowLayout {
                                id: body
                                anchors.fill: parent
                                anchors.margins: Kirigami.Units.largeSpacing
                                spacing: Kirigami.Units.largeSpacing
                                QQC2.CheckBox {
                                    Layout.alignment: Qt.AlignTop
                                    checked: row.on
                                    onToggled: root.toggle(row.index, checked)
                                    Accessible.name: row.modelData.label
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Kirigami.Units.smallSpacing
                                        QQC2.Label {
                                            Layout.fillWidth: true; wrapMode: Text.Wrap
                                            textFormat: Text.PlainText; font.weight: Font.DemiBold
                                            text: row.modelData.label
                                        }
                                        Rectangle {
                                            visible: !!row.modelData.risk
                                            radius: height / 2
                                            implicitHeight: riskLabel.implicitHeight + Kirigami.Units.smallSpacing
                                            implicitWidth: riskLabel.implicitWidth + Kirigami.Units.largeSpacing * 2
                                            color: Qt.rgba(root.riskColor(row.modelData.risk).r, root.riskColor(row.modelData.risk).g, root.riskColor(row.modelData.risk).b, 0.15)
                                            border.color: root.riskColor(row.modelData.risk)
                                            QQC2.Label {
                                                id: riskLabel
                                                anchors.centerIn: parent
                                                text: root.riskText(row.modelData.risk || "")
                                                textFormat: Text.PlainText
                                                font: Kirigami.Theme.smallFont
                                                color: root.riskColor(row.modelData.risk)
                                            }
                                        }
                                    }
                                    QQC2.Label {
                                        Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                                        visible: text !== ""; opacity: 0.8
                                        text: row.modelData.detail || ""
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        visible: !!row.modelData.warn
                                        spacing: Kirigami.Units.smallSpacing
                                        Kirigami.Icon {
                                            Layout.alignment: Qt.AlignTop
                                            source: row.modelData.risk === "high" ? "dialog-error"
                                                  : row.modelData.risk === "medium" ? "dialog-warning" : "dialog-information"
                                            implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth
                                        }
                                        QQC2.Label {
                                            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                                            text: row.modelData.warn || ""
                                            color: row.modelData.risk === "high" ? Kirigami.Theme.negativeTextColor
                                                 : row.modelData.risk === "medium" ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.textColor
                                        }
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
                    Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.75
                    text: "Nothing changes yet: each fix is shown with its commands before it runs."
                    visible: root.d.note_nothing_yet !== false
                }
                QQC2.Button { text: "Cancel"; icon.name: "dialog-cancel"; onClicked: bridge.cancel() }
                QQC2.Button {
                    text: (root.d.ok || "Continue") + " (" + root.count + ")"
                    icon.name: "go-next"; highlighted: true; font.bold: true
                    enabled: root.count > 0 || root.d.allow_none === true
                    onClicked: root.done()
                }
            }
        }
    }
}
