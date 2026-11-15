// Security Check - every other dialog: messages, errors, questions and
// pick-one lists. The main window shows it over the current page, or as the
// whole content of a small window when nothing else is open, so its
// implicit size follows its content (up to maximumWidth x maximumHeight).
// The text comes from the root side as rich text it built (values from the
// PC are escaped there); buttons are listed left to right.
// finished({button: N}) or {button: N, tag: "..."} answers; the root side
// keeps only a button and a tag it offered.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

Item {
    id: page
    required property var input
    property string iconSource: ""
    readonly property string title: d.title || qsTr("Security Check")
    signal finished(var answer)
    signal cancelled()
    function primary() { if (primaryIndex >= 0 && primaryIndex < buttons.length) answer(primaryIndex) }
    function dismiss() { cancelled() }
    // A pick-one list starts on the picked row (Up and Down work at once);
    // without a list the main button has the focus, as in any dialog.
    function initialFocus() {
        for (var n = 0; n < radios.count; n++)
            if (radios.itemAt(n).checked) return radios.itemAt(n)
        var main = footerButtons.itemAt(primaryIndex)
        return main ? main.item : null
    }

    // The most room the dialog may take (set by the main window).
    property real maximumWidth: Kirigami.Units.gridUnit * 34
    property real maximumHeight: Kirigami.Units.gridUnit * 30

    readonly property var d: input || ({})
    readonly property var items: d.items || []
    readonly property var buttons: d.buttons || [{ "label": qsTr("OK") }]
    readonly property int primaryIndex: d.primary !== undefined ? d.primary : buttons.length - 1
    property string picked: {
        for (var n = 0; n < items.length; n++) if (items[n].on) return items[n].tag
        return items.length ? items[0].tag : ""
    }
    property bool showDetails: false

    // ---- size -----------------------------------------------------------
    // The width comes from what the content would like when nothing wraps
    // (never from the width the dialog was given, so the two cannot chase
    // each other); the text column is then laid out at exactly that width,
    // which makes the height the same whatever size the dialog is shown at.
    readonly property real margin: Kirigami.Units.gridUnit
    property real listWidth: 0          // the widest pick-one row, unwrapped
    readonly property real wantedWidth: Math.ceil(Math.max(
        Kirigami.Units.gridUnit * (d.details || items.length ? 26 : 20),
        head.implicitWidth + margin * 2,
        bodyText.visible ? bodyText.implicitWidth + margin * 2 : 0,
        listWidth + margin * 2,
        footer.implicitWidth))
    readonly property real textWidth: Math.min(wantedWidth, maximumWidth) - margin * 2
    implicitWidth: Math.min(wantedWidth, maximumWidth)
    implicitHeight: Math.ceil(Math.min(maximumHeight,
        header.implicitHeight + body.implicitHeight + footer.implicitHeight))

    function answer(n) {
        var a = { "button": n }
        if (items.length) a.tag = picked
        finished(a)
    }
    function kindIcon(k) {
        return k === "error" ? "dialog-error" : k === "warning" ? "dialog-warning"
             : k === "question" ? "dialog-question" : ""
    }
    function kindName(k) {
        return k === "error" ? qsTr("Error") : k === "warning" ? qsTr("Warning")
             : k === "question" ? qsTr("Question") : qsTr("Security Check")
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- header: smaller than a page's, a dialog is a short stop ----
        Rectangle {
            id: header
            Layout.fillWidth: true
            implicitHeight: head.implicitHeight + Kirigami.Units.largeSpacing * 2
            color: Kirigami.Theme.alternateBackgroundColor
            Kirigami.Theme.colorSet: Kirigami.Theme.Header
            Kirigami.Theme.inherit: false
            RowLayout {
                id: head
                anchors.fill: parent
                anchors.leftMargin: page.margin; anchors.rightMargin: page.margin
                anchors.topMargin: Kirigami.Units.largeSpacing; anchors.bottomMargin: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Icon {
                    source: page.kindIcon(page.d.kind) || page.iconSource
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: Kirigami.Units.iconSizes.medium; implicitHeight: implicitWidth
                    // An error, warning or question icon says what kind of
                    // dialog this is; the app's icon says nothing.
                    Accessible.ignored: page.kindIcon(page.d.kind) === ""
                    Accessible.role: Accessible.Graphic
                    Accessible.name: page.kindName(page.d.kind)
                }
                Kirigami.Heading {
                    Layout.fillWidth: true; level: 3; wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    text: page.d.title || qsTr("Security Check")
                    Accessible.role: Accessible.Heading
                }
            }
            Kirigami.Separator { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom }
        }

        QQC2.ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            contentHeight: body.implicitHeight
            clip: true

            ColumnLayout {
                id: body
                x: page.margin
                // Narrower only when the dialog was given less room than
                // it asked for (or a scroll bar takes some).
                width: page.width > 0 ? Math.min(page.textWidth, scroll.availableWidth - page.margin * 2) : page.textWidth
                spacing: Kirigami.Units.largeSpacing

                Item { implicitHeight: Kirigami.Units.smallSpacing }

                QQC2.Label {
                    id: bodyText
                    Layout.fillWidth: true
                    visible: text !== ""
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                    text: page.d.html || ""
                }

                // Pick one (with each item's risk and warning).
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: page.items.length > 0
                    spacing: 0
                    Repeater {
                        id: radios
                        model: page.items
                        // The list is one stop for Tab, at the picked
                        // row; Up and Down pick the row before or after
                        // it, and Enter answers with the picked row (the
                        // dialog's main button).
                        delegate: QQC2.RadioDelegate {
                            id: radio
                            required property var modelData
                            required property int index
                            // The focus first: the row that is left stops
                            // being a Tab stop, which it cannot while it
                            // has the focus.
                            function pick() { forceActiveFocus(Qt.TabFocusReason); checked = true }
                            focusPolicy: checked ? Qt.StrongFocus : Qt.ClickFocus
                            Keys.onDownPressed: function (event) {
                                var next = radios.itemAt(index + 1)
                                if (next) next.pick(); else event.accepted = false
                            }
                            Keys.onUpPressed: function (event) {
                                var prev = radios.itemAt(index - 1)
                                if (prev) prev.pick(); else event.accepted = false
                            }
                            Layout.fillWidth: true
                            leftPadding: radio.indicator.width + radio.spacing * 2
                            // The style draws the highlight of a row from
                            // "inset - (padding - inset)" on each side, which
                            // put it on the dialog's left edge and short of
                            // the right one. Half the padding makes that 0:
                            // the highlight is as wide as the row, with the
                            // dialog's margin on both sides.
                            leftInset: leftPadding / 2
                            rightInset: rightPadding / 2
                            Component.onCompleted: { checked = page.picked === modelData.tag; page.listWidth = Math.max(page.listWidth, implicitWidth) }
                            onImplicitWidthChanged: page.listWidth = Math.max(page.listWidth, implicitWidth)
                            onCheckedChanged: if (checked) page.picked = modelData.tag
                            onActiveFocusChanged: if (activeFocus) Util.reveal(scroll.contentItem, radio, 0)
                            Accessible.name: Util.riskLabel(modelData.label, modelData.risk)
                            Accessible.description: Util.describe(modelData.detail, modelData.warn)
                            contentItem: ColumnLayout {
                                spacing: 0
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing
                                    QQC2.Label {
                                        Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                                        font.weight: Font.DemiBold; text: radio.modelData.label
                                    }
                                    StatusChip {
                                        visible: !!radio.modelData.risk
                                        Layout.alignment: Qt.AlignTop
                                        risk: radio.modelData.risk || ""
                                        Accessible.ignored: true
                                    }
                                }
                                QQC2.Label {
                                    Layout.fillWidth: true; visible: !!radio.modelData.detail
                                    wrapMode: Text.Wrap; textFormat: Text.PlainText
                                    opacity: Util.dimText; text: radio.modelData.detail || ""
                                }
                                QQC2.Label {
                                    Layout.fillWidth: true; visible: !!radio.modelData.warn
                                    wrapMode: Text.Wrap; textFormat: Text.PlainText
                                    text: radio.modelData.warn || ""
                                    color: Util.riskWarnColor(Kirigami.Theme, radio.modelData.risk)
                                }
                            }
                        }
                    }
                }

                // Error details, folded.
                QQC2.Button {
                    visible: !!page.d.details
                    flat: true
                    text: page.showDetails ? qsTr("Hide details") : qsTr("Show details")
                    icon.name: page.showDetails ? "go-up" : "go-down"
                    onClicked: page.showDetails = !page.showDetails
                }
                CodeBlock {
                    visible: page.showDetails && !!page.d.details
                    text: page.d.details || ""
                    flickable: scroll.contentItem
                }

                Item { implicitHeight: Kirigami.Units.smallSpacing }
            }
        }

        FooterBar {
            id: footer
            // One button per entry: the main one filled, the others plain.
            // Enter presses the one with the keyboard focus (the window
            // sees to it), else the main one.
            Repeater {
                id: footerButtons
                model: page.buttons
                delegate: Loader {
                    id: slot
                    required property var modelData
                    required property int index
                    sourceComponent: index === page.primaryIndex ? mainButton : plainButton
                    Component {
                        id: plainButton
                        QQC2.Button {
                            text: slot.modelData.label
                            icon.name: slot.modelData.icon || ""
                            onClicked: page.answer(slot.index)
                        }
                    }
                    Component {
                        id: mainButton
                        PrimaryButton {
                            text: slot.modelData.label
                            icon.name: slot.modelData.icon || ""
                            onClicked: page.answer(slot.index)
                        }
                    }
                }
            }
        }
    }
}
