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

Item {
    id: page
    required property var input
    property string iconSource: ""
    readonly property string title: d.title || qsTr("Security Check")
    signal finished(var answer)
    signal cancelled()
    function primary() { if (primaryIndex >= 0 && primaryIndex < buttons.length) answer(primaryIndex) }
    function dismiss() { cancelled() }

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
    function riskColor(r) {
        return r === "high" ? Kirigami.Theme.negativeTextColor : r === "medium" ? Kirigami.Theme.neutralTextColor
             : r === "low" ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor
    }
    function riskText(r) {
        return r === "high" ? qsTr("High risk") : r === "medium" ? qsTr("Medium risk") : r === "low" ? qsTr("Low risk") : (r || "")
    }
    // Keep what has the keyboard focus inside the visible part.
    function reveal(item) {
        var f = scroll.contentItem
        var top = item.mapToItem(f.contentItem, 0, 0).y
        if (top < f.contentY)
            f.contentY = Math.max(0, top)
        else if (top + item.height > f.contentY + f.height)
            f.contentY = Math.min(Math.max(0, f.contentHeight - f.height), top + item.height - f.height)
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
                        // A delegate takes no keyboard focus by itself
                        // (a list view would move through them), so each
                        // row does: Tab stops at the picked one, Up and
                        // Down pick the one before or after it.
                        delegate: QQC2.RadioDelegate {
                            id: radio
                            required property var modelData
                            required property int index
                            function pick() { checked = true; forceActiveFocus(Qt.TabFocusReason) }
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
                            // The one picked at the start has the keyboard
                            // focus, so Up and Down work at once.
                            focus: checked
                            Component.onCompleted: { checked = page.picked === modelData.tag; page.listWidth = Math.max(page.listWidth, implicitWidth) }
                            onImplicitWidthChanged: page.listWidth = Math.max(page.listWidth, implicitWidth)
                            onCheckedChanged: if (checked) page.picked = modelData.tag
                            onActiveFocusChanged: if (activeFocus) page.reveal(radio)
                            Accessible.name: modelData.risk ? qsTr("%1, %2").arg(modelData.label).arg(page.riskText(modelData.risk)) : modelData.label
                            Accessible.description: [modelData.detail || "", modelData.warn || ""].filter(function (s) { return s !== "" }).join(". ")
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
                                        text: page.riskText(radio.modelData.risk)
                                        tint: page.riskColor(radio.modelData.risk)
                                        Accessible.ignored: true
                                    }
                                }
                                QQC2.Label {
                                    Layout.fillWidth: true; visible: !!radio.modelData.detail
                                    wrapMode: Text.Wrap; textFormat: Text.PlainText
                                    opacity: 0.8; text: radio.modelData.detail || ""
                                }
                                QQC2.Label {
                                    Layout.fillWidth: true; visible: !!radio.modelData.warn
                                    wrapMode: Text.Wrap; textFormat: Text.PlainText
                                    text: radio.modelData.warn || ""
                                    color: radio.modelData.risk === "high" ? Kirigami.Theme.negativeTextColor
                                         : radio.modelData.risk === "medium" ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.textColor
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
                    Keys.onShortcutOverride: function (event) { event.accepted = event.key === Qt.Key_Return || event.key === Qt.Key_Enter }
                    Keys.onReturnPressed: clicked()
                    Keys.onEnterPressed: clicked()
                }
                CodeBlock {
                    visible: page.showDetails && !!page.d.details
                    text: page.d.details || ""
                }

                Item { implicitHeight: Kirigami.Units.smallSpacing }
            }
        }

        FooterBar {
            id: footer
            Repeater {
                model: page.buttons
                // Both kinds of button are declared; only the one that fits
                // is there (the hidden one takes no room and no focus).
                delegate: RowLayout {
                    id: slot
                    required property var modelData
                    required property int index
                    readonly property bool main: index === page.primaryIndex
                    spacing: 0
                    QQC2.Button {
                        visible: !slot.main
                        text: slot.modelData.label
                        icon.name: slot.modelData.icon || ""
                        onClicked: page.answer(slot.index)
                        // With the keyboard focus on it, Enter presses this
                        // button, not the main one.
                        Keys.onShortcutOverride: function (event) { event.accepted = event.key === Qt.Key_Return || event.key === Qt.Key_Enter }
                        Keys.onReturnPressed: clicked()
                        Keys.onEnterPressed: clicked()
                    }
                    PrimaryButton {
                        visible: slot.main
                        // No pick-one list: the main button starts with the
                        // keyboard focus, as in any dialog.
                        focus: slot.main && page.items.length === 0
                        text: slot.modelData.label
                        icon.name: slot.modelData.icon || ""
                        onClicked: page.answer(slot.index)
                    }
                }
            }
        }
    }
}
