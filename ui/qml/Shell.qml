// Security Check - the one window. It stays open for the whole run of the
// tool and shows, one after the other, the pages the root side asks for
// (ui/app.py passes each request on as host.request). A page is an Item
// with: required property var input, property string iconSource, a title,
// signals finished(answer) and cancelled(), and functions primary() (Enter)
// and dismiss() (Esc). A page may also have initialFocus(), which returns
// the item that gets the keyboard focus when the page is shown. Between two
// requests the last page stays (dimmed, under a spinner, when the next one
// takes a while), so the window never goes away while the tool works.
// "dialog" requests (Dialog.qml, sized by its content) are shown over the
// current page; when there is no page yet, the dialog is the whole content
// of a small window, which grows when the first page arrives.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQuick.Templates as T
import org.kde.kirigami as Kirigami

Kirigami.ApplicationWindow {
    id: root

    property var host: null             // ui/app.py: request, busy, park; reply()
    property string iconSource: ""      // file URL of the app icon

    property Item pageSlot: null        // holds the current page
    property Item pageItem: null        // the page (or a dialog shown alone)
    property bool pageIsDialog: false
    property Item dialogSlot: null      // holds a dialog shown over the page
    property Item dialogItem: null
    property string pendingId: ""       // the request waiting for an answer
    property bool compact: true         // small, until the first full page
    property bool wanted: false         // something has been shown
    property bool parked: false         // hidden: the scan's progress window shows
    property string busyLabel: ""       // what the root side says it is doing
    property bool busyShown: false      // dimmed, with the spinner
    // A page or dialog that has just appeared takes no keys and no clicks
    // for this long (ms): an Enter or a double click meant for the page
    // before it must not answer it too (the next page may be "Apply").
    // The time starts again with every key event and while a mouse button
    // is down, so a key or button that is still held, or repeating, when
    // the page appears cannot answer it either: see hold().
    readonly property int settleTime: 350
    // True until the page shown can be operated (tests wait for false).
    readonly property bool settling: settle.running
    property bool mouseDown: false      // a mouse button is down in the window
    property Item resume: null          // had the focus when hold() took it
    property bool resumeRing: false     // ... with a focus ring

    readonly property Item current: dialogItem || pageItem
    readonly property real compactWidth: pageItem ? pageItem.implicitWidth : Kirigami.Units.gridUnit * 22
    readonly property real compactHeight: pageItem ? pageItem.implicitHeight : Kirigami.Units.gridUnit * 8
    // More than any screen: no upper limit.
    readonly property int unlimited: 16777215

    title: (current && current.title) || qsTr("Security Check")
    visible: wanted && !parked
    width: Kirigami.Units.gridUnit * 22
    height: Kirigami.Units.gridUnit * 8
    minimumWidth: compact ? compactWidth : Kirigami.Units.gridUnit * 34
    minimumHeight: compact ? compactHeight : Kirigami.Units.gridUnit * 28
    maximumWidth: compact ? compactWidth : unlimited
    maximumHeight: compact ? compactHeight : unlimited
    pageStack.globalToolBar.style: Kirigami.ApplicationHeaderStyle.None

    // A dialog shown alone gives the window its size (and changes it, when
    // its details are opened).
    onCompactWidthChanged: if (compact) fit()
    onCompactHeightChanged: if (compact) fit()
    function fit() {
        if (compact) {
            width = compactWidth
            height = compactHeight
        } else {
            width = Kirigami.Units.gridUnit * 50
            height = Kirigami.Units.gridUnit * 40
        }
    }

    // The close button answers "cancelled", as closing a page's own window
    // did. The tool decides what comes next: it ends (and this front end
    // with it), or it sends the next page. With nothing to answer, the
    // window just gets out of the way until the next page; the work goes on.
    onClosing: (close) => {
        close.accepted = false
        if (pendingId !== "")
            finish(pendingId, 1, null)
        else
            wanted = false
    }

    // A button released while the window was hidden or not the active one
    // is not seen here: do not wait for it.
    onActiveChanged: if (!active) mouseDown = false
    onVisibleChanged: if (!visible) mouseDown = false

    Connections {
        target: root.host
        function onRequest(id, mode, url, input) { root.showRequest(id, mode, url, input) }
        function onBusy(label) { root.showBusy(label) }
        function onPark(on) { root.parked = on }
    }

    // ---- requests ---------------------------------------------------------
    function fail(id, why) {
        console.warn("Security Check: " + why)
        if (host) host.reply(id, 3, null)
    }

    // Every request gets an answer, whatever goes wrong here: the root
    // side waits for it without a time limit.
    function showRequest(id, mode, url, input) {
        const made = { "slot": null }
        try {
            present(id, mode, url, input, made)
        } catch (e) {
            // A slot that did not become the page would stay over it,
            // unseen, and take its clicks.
            if (made.slot && made.slot !== pageSlot && made.slot !== dialogSlot)
                made.slot.destroy()
            if (pendingId === id) pendingId = ""
            fail(id, "cannot show " + url + ": " + e)
        }
    }

    function isSignal(s) { return !!s && typeof s.connect === "function" }

    function present(id, mode, url, input, made) {
        if (pendingId !== "")
            finish(pendingId, 1, null)      // never two questions at once
        const component = Qt.createComponent(url)
        if (component.status !== Component.Ready) {
            fail(id, "cannot load " + url + ": " + component.errorString())
            return
        }
        const isDialog = mode === "dialog"
        const over = isDialog && pageItem !== null && !pageIsDialog
        const slot = (over ? dialogSlotComponent : pageSlotComponent).createObject(over ? dialogLayer : pageLayer)
        made.slot = slot
        const item = component.createObject(slot, { "input": input, "iconSource": root.iconSource })
        if (!item || !(item instanceof Item) || !isSignal(item.finished) || !isSignal(item.cancelled)) {
            if (item) item.destroy()
            slot.destroy()
            made.slot = null
            fail(id, url + " is not a page")
            return
        }
        item.anchors.fill = slot
        item.finished.connect(function (answer) { root.finish(id, 0, answer) })
        item.cancelled.connect(function () { root.finish(id, 1, null) })
        if (isDialog && item.maximumWidth !== undefined) {
            // Over a page: inside the window, with the page visible around
            // it. Alone: what fits on the screen.
            item.maximumWidth = Qt.binding(() => over
                ? Math.max(Kirigami.Units.gridUnit * 16, Math.min(Kirigami.Units.gridUnit * 40, root.width - Kirigami.Units.gridUnit * 4))
                : Math.min(Kirigami.Units.gridUnit * 40, Math.max(Kirigami.Units.gridUnit * 16, root.screen.desktopAvailableWidth - Kirigami.Units.gridUnit * 4)))
            item.maximumHeight = Qt.binding(() => over
                ? Math.max(Kirigami.Units.gridUnit * 10, root.height - Kirigami.Units.gridUnit * 4)
                : Math.min(Kirigami.Units.gridUnit * 36, Math.max(Kirigami.Units.gridUnit * 10, root.screen.desktopAvailableHeight - Kirigami.Units.gridUnit * 6)))
        }
        if (over) {
            if (dialogSlot) dialogSlot.destroy()
            dialogSlot = slot
            dialogItem = item
        } else {
            const old = pageSlot
            const resized = compact
            if (dialogSlot) { dialogSlot.destroy(); dialogSlot = null; dialogItem = null }
            pageSlot = slot
            pageItem = item
            pageIsDialog = isDialog
            if (!isDialog && compact) {
                compact = false     // lifts the size limits first
                fit()
            }
            if (old) {
                // The new page fades in over the old one, which then goes.
                // No fade when the window changes its size with the page.
                old.enabled = false
                old.focus = false
                old.z = -1
                old.destroy(resized ? 0 : Kirigami.Units.longDuration + 50)
            }
            if (resized || !old) slot.instant = true
        }
        pendingId = id
        busyShown = false
        busyLabel = ""
        grace.stop()
        slot.item = item
        slot.shown = true
        // The keyboard focus stays with the window, away from the pages,
        // until the new one has settled: see settleTime.
        resume = null
        unfocus()
        settle.restart()
        const hidden = !visible
        wanted = true
        if (hidden && visible) { raise(); requestActivate() }
    }

    // finish ID STATUS ANSWER - the page or dialog answered (0), was
    // cancelled or closed (1). Only the request that is waiting is answered;
    // a second click on a page that already answered does nothing.
    function finish(id, status, answer) {
        if (id === "" || id !== pendingId) return
        pendingId = ""
        if (dialogSlot) {
            const slot = dialogSlot
            dialogSlot = null
            dialogItem = null
            slot.enabled = false
            slot.shown = false
            slot.destroy(Kirigami.Units.longDuration + 50)
        }
        // The next page usually comes at once: only when it does not, the
        // page is dimmed and the spinner shown.
        grace.restart()
        if (host) host.reply(id, status, answer)
    }

    function showBusy(label) {
        busyLabel = label
        if (label === "" || pendingId !== "") return
        grace.stop()
        busyShown = true
        const hidden = !visible
        wanted = true
        if (hidden && visible) { raise(); requestActivate() }
    }

    // The page has settled: it gets the keyboard focus, on the control it
    // names (or, without one, wherever its own "focus: true" says; with
    // neither, on no control: Tab goes to the first one). After hold() the
    // focus goes back to the control it was taken from.
    Timer {
        id: settle
        interval: root.settleTime
        onTriggered: {
            if (root.mouseDown) { restart(); return }
            const slot = root.dialogSlot || root.pageSlot
            const back = root.resume, ring = root.resumeRing
            root.resume = null
            if (!slot || root.pendingId === "") return
            slot.forceActiveFocus()
            if (root.usable(back) && root.inside(back, slot)) {
                back.forceActiveFocus(ring ? Qt.TabFocusReason : Qt.OtherFocusReason)
                return
            }
            const first = root.current && root.current.initialFocus ? root.current.initialFocus() : null
            if (root.usable(first)) first.forceActiveFocus()
        }
    }

    // The keyboard focus leaves the pages and stays with the window, where
    // every key event comes to keyPressed() and keyReleased().
    function unfocus() {
        if (pageSlot) pageSlot.focus = false
        if (dialogSlot) dialogSlot.focus = false
        content.forceActiveFocus()
    }
    function inside(item, ancestor) {
        for (let p = item; p; p = p.parent)
            if (p === ancestor) return true
        return false
    }
    // hold - a key that can answer a page is held down (it repeats) while
    // a page waits for its answer. A button would take each repeat of
    // Space as a new click, so the page stops taking input, as when it
    // appeared, until the key has been up for settleTime. This is what
    // keeps a key held since the page before from answering this one: its
    // first repeat can come later than settleTime after the page appeared.
    function hold() {
        if (pendingId === "") return
        if (!settling) {
            const f = activeFocusItem, slot = dialogSlot || pageSlot
            resume = f && slot && inside(f, slot) ? f : null
            resumeRing = !!resume && resume.visualFocus === true
            unfocus()
        }
        settle.restart()
    }
    function answers(key) {
        return key === Qt.Key_Space || key === Qt.Key_Return || key === Qt.Key_Enter
            || key === Qt.Key_Escape || key === Qt.Key_Select
    }

    Timer {
        id: grace
        interval: Kirigami.Units.veryLongDuration
        onTriggered: if (root.pendingId === "") root.busyShown = true
    }

    // ---- keys -------------------------------------------------------------
    // Esc and Enter reach this only when the control with the keyboard
    // focus did not use them itself (an open combo box takes both): then
    // Esc is the page's dismiss() and Enter its primary(). Two exceptions
    // for Enter: in a text field or text block it does nothing here, and on
    // a button it presses that button, whatever the desktop's settings say
    // about buttons and Enter. A control that can be ticked (a check box,
    // a switch, a radio row, a row of the Choose page, an option card of
    // the wizard: "checkable") is not a button in that sense: Space ticks
    // it, and Enter is primary(), as in any dialog.
    // A key that is held down (auto-repeat) never answers anything, and a
    // page that has just appeared takes no keys at all: see settleTime and
    // hold().
    function usable(item) {
        // A control hidden or switched off after it got the focus (a button
        // of another wizard step) keeps it, but is not there for the user.
        return !!item && item.visible && item.enabled && item.focusPolicy !== Qt.NoFocus
    }
    function keyPressed(event) {
        // Not even Tab: it would move the focus into the new page. Any key
        // starts the wait again: the page is for a person who has let go.
        if (settling) { settle.restart(); event.accepted = true; return }
        if (pendingId === "" || !current) return
        if (event.isAutoRepeat && answers(event.key)) { hold(); event.accepted = true; return }
        if (event.modifiers & ~Qt.KeypadModifier) return
        const esc = event.key === Qt.Key_Escape
        const enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
        if (!esc && !enter) return
        const f = usable(root.activeFocusItem) ? root.activeFocusItem : null
        if (enter && (f instanceof TextInput || f instanceof TextEdit)) return
        event.accepted = true
        if (esc) {
            if (current.dismiss) current.dismiss()
        } else if (f instanceof T.AbstractButton && !f.checkable) {
            if (typeof f.click === "function") f.click()
            else f.clicked()
        } else if (current.primary) {
            current.primary()
        }
    }

    function keyReleased(event) {
        if (settling) { settle.restart(); event.accepted = true; return }
        // The release half of a repeat that the focused control did not
        // take, because it never saw the press: the key is held.
        if (pendingId !== "" && event.isAutoRepeat && answers(event.key)) { hold(); event.accepted = true }
    }
    // Every key press is announced first (so that a control can keep it
    // from being a shortcut). A repeat of a held key is caught here, before
    // the control with the focus would take it as a press.
    function keyAnnounced(event) {
        if (pendingId !== "" && !settling && event.isAutoRepeat && answers(event.key)) hold()
        event.accepted = false
    }

    // A closed combo box swallows Enter without doing anything with it:
    // there, Enter is the page's primary() as everywhere else.
    Shortcut {
        sequences: ["Return", "Enter"]
        autoRepeat: false
        enabled: root.pendingId !== "" && !root.settling && root.activeFocusItem instanceof T.ComboBox
                 && !(root.activeFocusItem.popup && root.activeFocusItem.popup.visible)
        onActivated: if (root.current && root.current.primary) root.current.primary()
    }

    // One page: a focus scope of its own (so each page keeps its own
    // keyboard focus), opaque, so a new page can fade in over the old one.
    Component {
        id: pageSlotComponent
        FocusScope {
            id: slot
            property Item item: null
            property bool shown: false
            property bool instant: false
            anchors.fill: parent
            opacity: shown ? 1 : 0
            Behavior on opacity {
                enabled: !slot.instant
                NumberAnimation { duration: Kirigami.Units.longDuration; easing.type: Easing.InOutQuad }
            }
            Rectangle { anchors.fill: parent; z: -1; color: Kirigami.Theme.backgroundColor }
        }
    }

    // A dialog over the page: a card in the middle, as large as the dialog
    // wants to be.
    Component {
        id: dialogSlotComponent
        FocusScope {
            id: card
            property Item item: null
            property bool shown: false
            property bool instant: false
            anchors.centerIn: parent
            width: item ? item.implicitWidth : 0
            height: item ? item.implicitHeight : 0
            opacity: shown ? 1 : 0
            scale: shown ? 1 : 0.96
            Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration; easing.type: Easing.OutQuad } }
            Behavior on scale { NumberAnimation { duration: Kirigami.Units.shortDuration; easing.type: Easing.OutQuad } }
            Accessible.role: Accessible.Dialog
            Accessible.name: item && item.title ? item.title : qsTr("Security Check")
            Kirigami.ShadowedRectangle {
                anchors.fill: parent
                z: -1
                color: Kirigami.Theme.backgroundColor
                radius: Kirigami.Units.smallSpacing
                shadow.size: Kirigami.Units.gridUnit
                shadow.yOffset: Kirigami.Units.smallSpacing
            }
            // The outline, over the dialog's own coloured parts.
            Rectangle {
                anchors.fill: parent
                z: 1
                color: "transparent"
                radius: Kirigami.Units.smallSpacing
                border.width: 1
                border.color: Kirigami.ColorUtils.linearInterpolation(Kirigami.Theme.backgroundColor, Kirigami.Theme.textColor, 0.25)
            }
            // Clicks beside the buttons stay in the dialog.
            MouseArea { anchors.fill: parent; z: -1; acceptedButtons: Qt.AllButtons }
        }
    }

    FocusScope {
        id: content
        anchors.fill: parent
        focus: true
        Keys.onPressed: (event) => root.keyPressed(event)
        Keys.onReleased: (event) => root.keyReleased(event)
        Keys.onShortcutOverride: (event) => root.keyAnnounced(event)

        // The page. While a dialog is over it, or the tool is busy, it is
        // dimmed and takes no input (and no keyboard focus: Tab stays in
        // the dialog).
        Item {
            id: pageLayer
            anchors.fill: parent
            enabled: !root.busyShown && root.dialogItem === null
            opacity: root.busyShown || root.dialogItem !== null ? 0.35 : 1
            Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }
        }
        // Until the spinner shows, a page that has answered already takes
        // no more clicks.
        MouseArea {
            anchors.fill: parent
            visible: root.pendingId === "" || root.dialogItem !== null
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onWheel: (wheel) => { wheel.accepted = true }
        }
        Item {
            id: dialogLayer
            anchors.fill: parent
        }
        // A page or dialog that has just appeared takes no clicks yet, and
        // its buttons do not light up under the pointer as if they did.
        MouseArea {
            anchors.fill: parent
            visible: root.settling
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onWheel: (wheel) => { wheel.accepted = true }
        }

        // Busy: what the tool is doing, between two pages.
        Rectangle {
            id: busyCard
            anchors.centerIn: parent
            visible: opacity > 0
            opacity: root.busyShown ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }
            width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, busyRow.implicitWidth + Kirigami.Units.gridUnit * 2)
            height: busyRow.implicitHeight + Kirigami.Units.gridUnit * 1.5
            radius: Kirigami.Units.smallSpacing
            // Alone in the small window it needs no card around it.
            color: root.pageItem ? Kirigami.Theme.backgroundColor : "transparent"
            border.width: root.pageItem ? 1 : 0
            border.color: Kirigami.ColorUtils.linearInterpolation(Kirigami.Theme.backgroundColor, Kirigami.Theme.textColor, 0.25)
            Accessible.role: Accessible.StatusBar
            Accessible.name: busyText.text
            RowLayout {
                id: busyRow
                anchors.centerIn: parent
                width: Math.min(implicitWidth, busyCard.width - Kirigami.Units.gridUnit * 2)
                spacing: Kirigami.Units.largeSpacing
                QQC2.BusyIndicator {
                    running: root.busyShown && root.visible
                    implicitWidth: Kirigami.Units.iconSizes.medium
                    implicitHeight: implicitWidth
                    Accessible.ignored: true
                }
                QQC2.Label {
                    id: busyText
                    Layout.fillWidth: true
                    text: root.busyLabel !== "" ? root.busyLabel : qsTr("Working…")
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    Accessible.ignored: true
                }
            }
        }

        // Over everything, taking nothing: it sees every press and release
        // of a mouse button in the window, whatever the click is for. A
        // button that is down holds the page back as a key does: see
        // settleTime.
        Item {
            anchors.fill: parent
            PointHandler {
                acceptedButtons: Qt.AllButtons
                onActiveChanged: {
                    root.mouseDown = active
                    if (root.settling) settle.restart()
                }
            }
        }
    }
}
