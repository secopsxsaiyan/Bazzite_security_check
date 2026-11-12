// Security Check - every other dialog (Kirigami), in the wizard's style:
// messages, pages, errors, questions and pick-one lists. The text comes from
// the root side as rich text it built (values from the PC are escaped
// there); buttons are listed left to right, the primary one last.
// bridge.finish({button: N}) or {button: N, tag: "..."} answers; the root
// side keeps only a button and a tag it offered.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.ApplicationWindow {
    id: root
    title: "Security Check"
    readonly property var d: bridge.input
    readonly property var items: d.items || []
    readonly property var buttons: d.buttons || [{ "label": "OK" }]
    readonly property bool big: (d.html || "").length > 900 || items.length > 6 || !!d.details
    width: Kirigami.Units.gridUnit * (big ? 46 : 34)
    height: Kirigami.Units.gridUnit * (big ? 36 : 22)
    minimumWidth: Kirigami.Units.gridUnit * 26
    minimumHeight: Kirigami.Units.gridUnit * 14
    pageStack.globalToolBar.style: Kirigami.ApplicationHeaderStyle.None

    property string picked: {
        for (var n = 0; n < items.length; n++) if (items[n].on) return items[n].tag
        return items.length ? items[0].tag : ""
    }
    property bool showDetails: false

    function answer(n) {
        var a = { "button": n }
        if (items.length) a.tag = picked
        bridge.finish(a)
    }
    function kindIcon(k) {
        return k === "error" ? "dialog-error" : k === "warning" ? "dialog-warning"
             : k === "question" ? "dialog-question" : ""
    }
    function riskColor(r) {
        return r === "high" ? Kirigami.Theme.negativeTextColor : r === "medium" ? Kirigami.Theme.neutralTextColor
             : r === "low" ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor
    }

    onClosing: bridge.cancel()

    pageStack.initialPage: Kirigami.Page {
        padding: 0
        titleDelegate: Item {}

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

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
                        source: root.kindIcon(root.d.kind) || bridge.iconSource
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: Kirigami.Units.iconSizes.large; implicitHeight: implicitWidth
                    }
                    Kirigami.Heading {
                        Layout.fillWidth: true; level: 2; wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        text: root.d.title || "Security Check"
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
                    width: parent.width - Kirigami.Units.gridUnit * 2
                    x: Kirigami.Units.gridUnit
                    spacing: Kirigami.Units.largeSpacing

                    Item { implicitHeight: Kirigami.Units.smallSpacing }
                    QQC2.Label {
                        Layout.fillWidth: true
                        visible: text !== ""
                        wrapMode: Text.Wrap
                        textFormat: Text.RichText
                        text: root.d.html || ""
                    }

                    // Pick one (with each item's risk and warning).
                    Repeater {
                        model: root.items
                        delegate: QQC2.RadioDelegate {
                            id: radio
                            Layout.fillWidth: true
                            leftPadding: radio.indicator.width + radio.spacing * 2
                            checked: root.picked === modelData.tag
                            onClicked: root.picked = modelData.tag
                            contentItem: ColumnLayout {
                                spacing: 0
                                RowLayout {
                                    Layout.fillWidth: true
                                    QQC2.Label { Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText; font.weight: Font.DemiBold; text: modelData.label }
                                    QQC2.Label {
                                        visible: !!modelData.risk
                                        text: modelData.risk ? modelData.risk + " risk" : ""
                                        color: root.riskColor(modelData.risk); font: Kirigami.Theme.smallFont
                                    }
                                }
                                QQC2.Label { Layout.fillWidth: true; visible: !!modelData.detail; wrapMode: Text.Wrap; textFormat: Text.PlainText; opacity: 0.8; text: modelData.detail || "" }
                                QQC2.Label { Layout.fillWidth: true; visible: !!modelData.warn; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: modelData.warn || ""
                                             color: modelData.risk === "high" ? Kirigami.Theme.negativeTextColor : modelData.risk === "medium" ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.textColor }
                            }
                        }
                    }

                    // Error details, folded.
                    QQC2.Button {
                        visible: !!root.d.details
                        flat: true
                        text: root.showDetails ? "Hide details" : "Show details"
                        icon.name: root.showDetails ? "go-up" : "go-down"
                        onClicked: root.showDetails = !root.showDetails
                    }
                    QQC2.TextArea {
                        Layout.fillWidth: true
                        visible: root.showDetails
                        readOnly: true; wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText
                        font: Kirigami.Theme.fixedWidthFont
                        text: root.d.details || ""
                    }
                    Item { implicitHeight: Kirigami.Units.smallSpacing }
                }
            }

            Kirigami.Separator { Layout.fillWidth: true }
            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing
                Item { Layout.fillWidth: true }
                Repeater {
                    model: root.buttons
                    delegate: QQC2.Button {
                        required property var modelData
                        required property int index
                        text: modelData.label
                        icon.name: modelData.icon || ""
                        highlighted: index === (root.d.primary !== undefined ? root.d.primary : root.buttons.length - 1)
                        font.bold: highlighted
                        onClicked: root.answer(index)
                    }
                }
            }
        }
    }
}
