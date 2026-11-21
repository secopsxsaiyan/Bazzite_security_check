// Security Check - the one window. It stays open for the whole run of the
// tool and shows, one after the other, the pages the root side asks for
// (ui/app.py passes each request on as host.request). A page is an Item
// with: required property var input, property string iconSource, a title,
// signals finished(answer) and cancelled(), and functions primary() (Enter)
// and dismiss() (Esc). A page may also have initialFocus(), which returns
// the item that gets the keyboard focus when the page is shown, and a
// property scrollArea: the Flickable that PageUp, PageDown, Home, End and
// the arrow keys scroll (see scrollKey()). Between two requests the last
// page stays (dimmed, under a spinner, when the next one takes a while), so
// the window never goes away while the tool works.
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
    // The time starts again with every key event and with every press and
    // release of a mouse button, so a key that is still held, or repeating,
    // when the page appears cannot answer it either: see hold(). (A mouse
    // button held since the page before needs no such care: letting go of
    // it clicks nothing, because the new page never saw it go down.)
    readonly property int settleTime: 350
    // True until the page shown can be operated (tests wait for false).
    readonly property bool settling: settle.running
    // Alt is held down, as far as the key events of this window tell (a
    // release that never came here leaves it true until the next key
    // event, or until the window is no longer active). It shows an
    // underline and answers nothing: for the main button of a page that
    // appears while Alt is held, see PrimaryButton.qml.
    property bool altDown: false
    onActiveChanged: if (!active) altDown = false
    // The window was hidden and has not drawn the page since: see below.
    property bool unseen: false
    property Item resume: null          // had the focus when hold() took it
    property bool resumeRing: false     // ... with a focus ring

    readonly property Item current: dialogItem || pageItem
    // Only a dialog has a size of its own. A width or height of 0 must never
    // reach the window: a Wayland compositor ends a program that asks for it.
    readonly property real compactWidth: pageItem && pageIsDialog && pageItem.implicitWidth > 0 ? pageItem.implicitWidth : Kirigami.Units.gridUnit * 22
    readonly property real compactHeight: pageItem && pageIsDialog && pageItem.implicitHeight > 0 ? pageItem.implicitHeight : Kirigami.Units.gridUnit * 8
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
    onClosing: function (close) {
        close.accepted = false
        if (pendingId !== "")
            finish(pendingId, 1, null)
        else
            wanted = false
    }

    // The settle pause is for the person: it counts from the first picture
    // of the page on the screen. A window that was hidden can take longer
    // than the pause to come up, so the pause starts again with the first
    // frame drawn after it was shown.
    onVisibleChanged: unseen = visible
    Connections {
        target: root
        enabled: root.unseen
        function onFrameSwapped() {
            root.unseen = false
            root.hold()
        }
    }

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
        var made = { "slot": null }
        try {
            present(id, mode, url, input, made)
        } catch (e) {
            // A slot that did not become the page or the dialog would
            // stay in the window, unseen, with what was made in it.
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
        var component = Qt.createComponent(url)
        if (component.status !== Component.Ready) {
            fail(id, "cannot load " + url + ": " + component.errorString())
            return
        }
        var isDialog = mode === "dialog"
        var over = isDialog && pageItem !== null && !pageIsDialog
        // The slot is made switched off, and switched on below, when what
        // it replaces is switched off: a button gets its Alt+letter key
        // when it is switched on, and the buttons of what is replaced
        // would still hold their letters. So a page that follows one with
        // the same buttons gives them the same keys. (A dialog that is
        // replaced was switched off before: finish().)
        var slot = (over ? dialogSlotComponent : pageSlotComponent).createObject(over ? dialogLayer : pageLayer, { "enabled": false })
        made.slot = slot
        var item = component.createObject(slot, { "input": input, "iconSource": root.iconSource })
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
            item.maximumWidth = Qt.binding(function () {
                return over
                    ? Math.max(Kirigami.Units.gridUnit * 16, Math.min(Kirigami.Units.gridUnit * 40, root.width - Kirigami.Units.gridUnit * 4))
                    : Math.min(Kirigami.Units.gridUnit * 40, Math.max(Kirigami.Units.gridUnit * 16, root.screen.desktopAvailableWidth - Kirigami.Units.gridUnit * 4))
            })
            item.maximumHeight = Qt.binding(function () {
                return over
                    ? Math.max(Kirigami.Units.gridUnit * 10, root.height - Kirigami.Units.gridUnit * 4)
                    : Math.min(Kirigami.Units.gridUnit * 36, Math.max(Kirigami.Units.gridUnit * 10, root.screen.desktopAvailableHeight - Kirigami.Units.gridUnit * 6))
            })
        }
        if (over) {
            if (dialogSlot) dialogSlot.destroy()
            dialogSlot = slot
            dialogItem = item
            slot.item = item        // the card takes the dialog's size
        } else {
            var old = pageSlot
            var resized = compact
            if (dialogSlot) { dialogSlot.destroy(); dialogSlot = null; dialogItem = null }
            // In this order: the size limits are lifted before the window
            // learns of a page that has no size of its own (and while the
            // small window still has the size of what it shows).
            if (!isDialog && compact) {
                compact = false
                fit()
            }
            pageIsDialog = isDialog
            pageSlot = slot
            pageItem = item
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
        slot.enabled = true
        pendingId = id
        busyShown = false
        busyLabel = ""
        grace.stop()
        slot.shown = true
        // The keyboard focus stays with the window, away from the pages,
        // until the new one has settled: see settleTime.
        resume = null
        unfocus()
        settle.restart()
        var hidden = !visible
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
            var slot = dialogSlot
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

    // A label that comes while a page waits for its answer is dropped: it
    // is not about the work that follows that answer.
    function showBusy(label) {
        if (pendingId !== "") return
        busyLabel = label
        if (label === "") return
        grace.stop()
        busyShown = true
        var hidden = !visible
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
            var slot = root.dialogSlot || root.pageSlot
            var back = root.resume, ring = root.resumeRing
            root.resume = null
            if (!slot || root.pendingId === "") return
            if (root.usable(back) && root.inside(back, slot)) {
                // Straight to the control, not to its page first: inside
                // the page it still has the focus, and would get the
                // keyboard focus back without its ring.
                back.forceActiveFocus(ring ? Qt.TabFocusReason : Qt.OtherFocusReason)
                return
            }
            slot.forceActiveFocus()
            var first = root.current && root.current.initialFocus ? root.current.initialFocus() : null
            // A plain button shows that it has the focus by itself. A tick
            // box or a row does not: it gets its ring, as after Tab, or
            // Space would tick something never shown as focused.
            if (root.usable(first)) first.forceActiveFocus(first.checkable === false ? Qt.OtherFocusReason : Qt.TabFocusReason)
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
        for (var p = item; p; p = p.parent)
            if (p === ancestor) return true
        return false
    }
    // hold - the settle pause starts (again) for the page that waits for
    // its answer: the page stops taking input, as when it appeared, and
    // gets the keyboard focus back when the pause is over. Called when a
    // key that can answer a page is held down (it repeats): a button would
    // take each repeat of Space as a new click, and each repeat of
    // Alt+letter is a button's shortcut again. This is what keeps a key
    // held since the page before from answering this one: its first repeat
    // can come later than settleTime after the page appeared.
    function hold() {
        if (pendingId === "") return
        if (!settling) {
            var f = activeFocusItem, slot = dialogSlot || pageSlot
            resume = f && slot && inside(f, slot) ? f : null
            resumeRing = !!resume && resume.visualFocus === true
            unfocus()
        }
        settle.restart()
    }
    // A key event that can answer a page: Space, Enter and Esc, and
    // anything with Alt (every button has an Alt+letter shortcut). Not a
    // key that only types: see typing().
    function answers(event) {
        var key = event.key
        if (typing(event)) return false
        return key === Qt.Key_Space || key === Qt.Key_Return || key === Qt.Key_Enter
            || key === Qt.Key_Escape || key === Qt.Key_Select
            || (event.modifiers & Qt.AltModifier) !== 0
    }
    // A key event that types into the text field with the keyboard focus,
    // if that field can be edited: Space, and Enter where it starts a new
    // line (a text area). Held down, such a key repeats as in any text
    // field, and hold() leaves it alone: it answers nothing. Everything
    // else stays guarded there too: Esc, anything with Alt, Enter in a
    // one-line field (which may take Enter as "done"), and every key in a
    // field that is read-only.
    function typing(event) {
        var f = activeFocusItem, key = event.key
        if ((event.modifiers & Qt.AltModifier) !== 0 || !usable(f) || f.readOnly !== false) return false
        if (key === Qt.Key_Space) return f instanceof TextInput || f instanceof TextEdit
        return (key === Qt.Key_Return || key === Qt.Key_Enter) && f instanceof TextEdit
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
    // A page that has just appeared takes no keys at all, and a key that
    // is held down (auto-repeat) answers nothing, with one exception: Space
    // held on a button with the keyboard focus presses that button once,
    // on the page it was pressed on (the button takes the release half of
    // the first repeat as the end of the press). See settleTime and hold().
    function usable(item) {
        // A control hidden or switched off after it got the focus (a button
        // of another wizard step) keeps it, but is not there for the user.
        return !!item && item.visible && item.enabled && item.focusPolicy !== Qt.NoFocus
    }
    function sawKey(event, down) {
        // A held key that repeats comes as a release and a press: the
        // release half of a repeating Alt does not mean Alt is up.
        if (event.key === Qt.Key_Alt && event.isAutoRepeat) return
        altDown = event.key === Qt.Key_Alt ? down : (event.modifiers & Qt.AltModifier) !== 0
    }
    function keyPressed(event) {
        sawKey(event, true)
        // Not even Tab: it would move the focus into the new page. Any key
        // starts the wait again: the page is for a person who has let go.
        if (settling) { settle.restart(); event.accepted = true; return }
        if (pendingId === "" || !current) return
        if (event.isAutoRepeat && answers(event)) { hold(); event.accepted = true; return }
        // With Ctrl, Shift, Alt or Meta a key means something else.
        if (event.modifiers & ~Qt.KeypadModifier) return
        if (scrollKey(event.key)) { event.accepted = true; return }
        var esc = event.key === Qt.Key_Escape
        var enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
        if (!esc && !enter) return
        var f = usable(root.activeFocusItem) ? root.activeFocusItem : null
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

    // PageUp, PageDown, Home, End and the arrow keys scroll the page (or
    // the dialog over it) when the control with the keyboard focus did not
    // use them: text without a control in it is reached with the keyboard
    // too. The page names what scrolls (scrollArea, a Flickable); a page
    // without one has nothing to scroll. Returns true for a scroll key
    // that was used.
    function scrollKey(key) {
        var area = current ? current.scrollArea : null
        if (!area || typeof area.contentY !== "number") return false
        var top = area.originY - area.topMargin
        var bottom = Math.max(top, area.originY + area.contentHeight + area.bottomMargin - area.height)
        var page = area.height * 0.9, line = Kirigami.Units.gridUnit * 3
        var to
        switch (key) {
        case Qt.Key_PageDown: to = area.contentY + page; break
        case Qt.Key_PageUp: to = area.contentY - page; break
        case Qt.Key_End: to = bottom; break
        case Qt.Key_Home: to = top; break
        case Qt.Key_Down: to = area.contentY + line; break
        case Qt.Key_Up: to = area.contentY - line; break
        default: return false
        }
        area.contentY = Math.min(bottom, Math.max(top, to))
        return true
    }

    function keyReleased(event) {
        sawKey(event, false)
        if (settling) { settle.restart(); event.accepted = true; return }
        // The release half of a repeat that the focused control did not
        // take, because it never saw the press: the key is held. (For key
        // events that were not announced: see keyAnnounced().)
        if (pendingId !== "" && event.isAutoRepeat && answers(event)) { hold(); event.accepted = true }
    }
    // Every key press that comes from the keyboard is announced here
    // first, whichever control has the keyboard focus, and one that is
    // accepted here is not looked up as a shortcut. That matters because
    // every button has a shortcut (Alt and a letter of its label), and a
    // shortcut answers before keyPressed() is asked: so a page that
    // settles lets no key become a shortcut, and a repeat of a held key is
    // caught before a button's shortcut or the control with the focus
    // would take it as a new press. An accepted press goes on to
    // keyPressed() as a plain key. (Key events made by a program need not
    // be announced: for those, keyPressed() and keyReleased() do the same.)
    function keyAnnounced(event) {
        sawKey(event, true)
        if (settling) {
            event.accepted = true
        } else if (pendingId !== "" && event.isAutoRepeat && answers(event)) {
            hold()
            event.accepted = true
        } else {
            event.accepted = false
        }
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
                radius: Kirigami.Units.cornerRadius
                shadow.size: Kirigami.Units.gridUnit
                shadow.yOffset: Kirigami.Units.smallSpacing
            }
            // The outline, over the dialog's own coloured parts.
            Rectangle {
                anchors.fill: parent
                z: 1
                color: "transparent"
                radius: Kirigami.Units.cornerRadius
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
        Keys.onPressed: function (event) { root.keyPressed(event) }
        Keys.onReleased: function (event) { root.keyReleased(event) }
        Keys.onShortcutOverride: function (event) { root.keyAnnounced(event) }

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
            onWheel: function (wheel) { wheel.accepted = true }
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
            onWheel: function (wheel) { wheel.accepted = true }
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
            radius: Kirigami.Units.cornerRadius
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
        // of a mouse button in the window, whatever the click is for. While
        // a page settles, each one starts the wait again, as a key does:
        // clicking on and on does not answer the page that comes next.
        Item {
            anchors.fill: parent
            PointHandler {
                acceptedButtons: Qt.AllButtons
                onActiveChanged: if (root.settling) settle.restart()
            }
        }
    }
}
