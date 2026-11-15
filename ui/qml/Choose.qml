// Security Check - choose items (a page of the main window): the apps,
// ports, packages or problems a fix may change. Each item can be ticked on
// its own, with its risk and what could break; Select all / none (and "low
// risk only" when items are graded) set them at once.
// finished({tags: [...]}) answers; the root side keeps only tags it
// offered.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "util.js" as Util

Item {
    id: page
    required property var input
    property string iconSource: ""
    readonly property string title: d.title || qsTr("Choose")
    signal finished(var answer)
    signal cancelled()
    function primary() { if (canContinue) done() }
    function dismiss() { cancelled() }
    // The main button. Enter continues from anywhere on the page, also from
    // a row: a row is a check box, which Space ticks.
    function initialFocus() { return mainButton.enabled ? mainButton : rows.count > 0 ? rows.itemAt(currentRow) : cancelButton }
    readonly property Item scrollArea: scroll.contentItem

    readonly property var d: input || ({})
    readonly property var items: d.items || []
    readonly property bool graded: items.some(function (i) { return !!i.risk })
    property var picked: items.map(function (i) { return i.on === true })
    readonly property int count: picked.filter(function (p) { return p }).length
    readonly property bool canContinue: count > 0 || d.allow_none === true
    // The list is one stop for Tab: it stops at this row, and the arrow
    // keys, Home and End move between the rows.
    property int currentRow: 0

    function setAll(f) { picked = items.map(function (i, n) { return f(i, n) }) }
    function toggle(n, v) { var p = picked.slice(); p[n] = v; picked = p }
    function done() {
        var t = []
        for (var n = 0; n < items.length; n++) if (picked[n]) t.push(items[n].tag)
        finished({ "tags": t })
    }
    function goTo(n) {
        var row = rows.itemAt(Math.max(0, Math.min(rows.count - 1, n)))
        if (row) row.forceActiveFocus(Qt.TabFocusReason)
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        PageHeader {
            iconSource: page.iconSource
            title: page.d.title || qsTr("Choose")
            subtitle: page.d.intro || ""
        }

        // ---- select all / none / low risk ------------------------------
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.largeSpacing
            Layout.leftMargin: Kirigami.Units.gridUnit; Layout.rightMargin: Kirigami.Units.gridUnit
            spacing: Kirigami.Units.smallSpacing
            QQC2.Button { text: qsTr("Select all"); icon.name: "edit-select-all"; onClicked: page.setAll(function () { return true }) }
            QQC2.Button { text: qsTr("Select none"); icon.name: "edit-select-none"; onClicked: page.setAll(function () { return false }) }
            QQC2.Button {
                // Not where a tick keeps something (the firewall list):
                // there, unticking is the risky part.
                visible: page.graded && page.d.low_only !== false && page.items.some(function (i) { return i.risk === "low" })
                text: qsTr("Low risk only"); icon.name: "security-high"
                onClicked: page.setAll(function (i) { return i.risk === "low" })
            }
            QQC2.Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight; elide: Text.ElideLeft
                text: qsTr("%1 of %2 selected").arg(page.count).arg(page.items.length); opacity: Util.dimLabel
            }
        }

        QQC2.ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                x: Kirigami.Units.gridUnit
                width: Math.min(scroll.availableWidth - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 48)
                spacing: Kirigami.Units.smallSpacing

                // Room for the focus ring of the first item.
                Item { implicitHeight: Kirigami.Units.smallSpacing }
                Repeater {
                    id: rows
                    model: page.items
                    // One item: a card that is a check box as a whole
                    // (click anywhere; with the keyboard focus on it, Space
                    // ticks it, and Enter continues as on any check box).
                    delegate: QQC2.AbstractButton {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool on: page.picked[index] === true
                        readonly property color edge: on ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                        Layout.fillWidth: true
                        padding: Kirigami.Units.largeSpacing
                        hoverEnabled: true
                        // Really a check box, also for a screen reader. A
                        // click or Space replaces the binding of "checked",
                        // so it is put back.
                        checkable: true
                        checked: on
                        onToggled: {
                            page.toggle(index, checked)
                            checked = Qt.binding(function () { return row.on })
                        }
                        function flip() { page.toggle(index, !on) }
                        focusPolicy: index === page.currentRow ? Qt.StrongFocus : Qt.ClickFocus
                        onActiveFocusChanged: if (activeFocus) {
                            page.currentRow = index
                            Util.reveal(scroll.contentItem, row, Kirigami.Units.largeSpacing)
                        }
                        Keys.onDownPressed: page.goTo(index + 1)
                        Keys.onUpPressed: page.goTo(index - 1)
                        Keys.onPressed: function (event) {
                            if (event.key === Qt.Key_Home) page.goTo(0)
                            else if (event.key === Qt.Key_End) page.goTo(rows.count - 1)
                            else return
                            event.accepted = true
                        }

                        Accessible.role: Accessible.CheckBox
                        Accessible.name: Util.riskLabel(modelData.label, modelData.risk)
                        Accessible.description: Util.describe(modelData.detail, modelData.warn)
                        Accessible.onPressAction: flip()
                        Accessible.onToggleAction: flip()

                        background: Rectangle {
                            radius: Kirigami.Units.cornerRadius
                            color: row.on ? Qt.alpha(row.edge, row.hovered ? Util.tintOnHover : Util.tintOn)
                                 : row.hovered ? Qt.alpha(row.edge, Util.tintHover) : Kirigami.Theme.backgroundColor
                            border.color: Qt.alpha(row.edge, row.on ? Util.tintEdgeOn : Util.tintEdge)
                            FocusRing { target: row; cornerRadius: parent.radius }
                        }

                        contentItem: RowLayout {
                            spacing: Kirigami.Units.largeSpacing
                            // Only the tick mark: the card is the control.
                            QQC2.CheckBox {
                                Layout.alignment: Qt.AlignTop
                                checked: row.on
                                focusPolicy: Qt.NoFocus
                                Accessible.ignored: true
                                MouseArea { anchors.fill: parent; onClicked: row.flip() }
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
                                    StatusChip {
                                        visible: !!row.modelData.risk
                                        Layout.alignment: Qt.AlignTop
                                        risk: row.modelData.risk || ""
                                        Accessible.ignored: true
                                    }
                                }
                                QQC2.Label {
                                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                                    visible: text !== ""; opacity: Util.dimText
                                    text: row.modelData.detail || ""
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    visible: !!row.modelData.warn
                                    spacing: Kirigami.Units.smallSpacing
                                    // The icon and the chip above say how
                                    // risky; the warning is in the text
                                    // colour, so that it can be read.
                                    Kirigami.Icon {
                                        Layout.alignment: Qt.AlignTop
                                        source: Util.riskIcon(row.modelData.risk)
                                        implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: implicitWidth
                                        Accessible.ignored: true
                                    }
                                    QQC2.Label {
                                        Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                                        text: row.modelData.warn || ""
                                    }
                                }
                            }
                        }
                    }
                }

                QQC2.Label {
                    Layout.fillWidth: true; wrapMode: Text.Wrap
                    visible: page.items.length === 0; opacity: Util.dimLabel
                    text: qsTr("There is nothing to choose from.")
                }
                Item { implicitHeight: Kirigami.Units.largeSpacing }
            }
        }

        FooterBar {
            hint: page.d.note_nothing_yet !== false ? qsTr("Nothing changes yet: each fix is shown with its commands before it runs.") : ""
            QQC2.Button { id: cancelButton; text: qsTr("Cancel"); icon.name: "dialog-cancel"; onClicked: page.dismiss() }
            PrimaryButton {
                id: mainButton
                text: Util.fill(qsTr("%1 (%2)"), [page.d.ok || qsTr("Continue"), page.count])
                icon.name: "go-next"
                enabled: page.canContinue
                onClicked: page.primary()
            }
        }
    }
}
