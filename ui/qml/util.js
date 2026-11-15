// Security Check - helpers shared by the pages and components.
// Use: import "util.js" as Util
// A library has no theme of its own: the colour helpers take the caller's
// Kirigami.Theme, so they follow the colour set of the place they are used.
.pragma library

// Text from the PC inside a rich-text label: markup characters as text.
function esc(s) {
    return String(s === undefined || s === null ? "" : s)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// Text from the PC as the text of a tool tip. A tool tip shows its text as
// rich text whenever it looks like markup, so the text is escaped, and
// marked as rich text so that the escapes are always read as such.
function tip(s) {
    return "<span>" + esc(s).replace(/\n/g, "<br>") + "</span>"
}

// The label of a button with its Alt+letter key underlined, as styled
// text. MARKED is the label with "&" in front of that letter (Kirigami's
// MnemonicData.mnemonicLabel; "&&" is a real "&"). The label may hold text
// from the PC: everything else in it is escaped.
function mnemonic(marked) {
    var s = String(marked === undefined || marked === null ? "" : marked), out = "", done = false
    for (var n = 0; n < s.length; n++) {
        if (s[n] !== "&" || n + 1 >= s.length) { out += esc(s[n]); continue }
        n++
        if (s[n] === "&" || done) out += esc(s[n])
        else { out += "<u>" + esc(s[n]) + "</u>"; done = true }
    }
    return out
}

// Rich text as the plain text a screen reader should get: tags removed
// (a line break or the end of a block is a space), entities as characters.
function plain(html) {
    return String(html === undefined || html === null ? "" : html)
        .replace(/<(br|\/p|\/div|\/li|\/tr|\/h[1-6])\b[^>]*>/gi, " ")
        .replace(/<[^>]*>/g, "")
        .replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
        .replace(/&quot;/g, "\"").replace(/&#0*39;|&apos;/g, "'").replace(/&amp;/g, "&")
        .replace(/\s+/g, " ").trim()
}

// TEMPLATE with %1, %2, ... replaced by VALUES in one pass. For texts from
// the PC: unlike a chain of .arg(), a "%2" inside one value is left alone.
function fill(template, values) {
    return String(template).replace(/%([1-9])/g, function (m, d) {
        var v = values[Number(d) - 1]
        return v === undefined || v === null ? "" : String(v)
    })
}

// Descriptions are wrapped at about 78 columns in the checks: join those
// lines again (list lines and blank lines stay).
function reflow(s) {
    var out = [], lines = String(s === undefined || s === null ? "" : s).split("\n")
    var bullet = /^\s*[-•*]\s/
    for (var n = 0; n < lines.length; n++) {
        var l = lines[n], prev = out.length ? out[out.length - 1] : ""
        if (out.length && l.trim() !== "" && prev.trim() !== "" && !bullet.test(l) && !bullet.test(prev))
            out[out.length - 1] = prev + " " + l.trim()
        else
            out.push(l)
    }
    return out.join("\n")
}

// Scroll FLICKABLE so that ITEM (somewhere inside it) is in view, with GAP
// around it. Used when an item gets the keyboard focus.
function reveal(flickable, item, gap) {
    if (!flickable || !item)
        return
    var g = gap || 0
    var top = item.mapToItem(flickable.contentItem, 0, 0).y
    var last = Math.max(0, flickable.contentHeight - flickable.height)
    if (top - g < flickable.contentY)
        flickable.contentY = Math.max(0, Math.min(last, top - g))
    else if (top + item.height + g > flickable.contentY + flickable.height)
        flickable.contentY = Math.max(0, Math.min(last, top + item.height + g - flickable.height))
}

// Is ITEM inside ANCESTOR (or the same item)?
function within(item, ancestor) {
    for (var p = item; p; p = p.parent)
        if (p === ancestor) return true
    return false
}

// ---- how much is dimmed, and how strong a tint is ----------------------------
// Opacity of text that is not the main thing where it stands.
var dimSentence = 0.85  // a sentence that still has to be read
var dimText = 0.8       // descriptions, explanations, hints
var dimLabel = 0.75     // the name of a value, a count, a small line
var dimQuiet = 0.7      // what needs no attention: a check without findings
var dimMark = 0.6       // a mark that only decorates (the arrow of a row)
// A card that can be ticked (Choose): the share of its colour in the fill
// and in the frame.
var tintHover = 0.05    // not ticked, under the pointer
var tintOn = 0.10       // ticked
var tintOnHover = 0.16  // ticked, under the pointer
var tintEdge = 0.15     // the frame
var tintEdgeOn = 0.6    // the frame when ticked

// A state colour as the colour of text. The state colours of a theme are
// made for icons, fills and frames: as text on the page they are too pale
// to read, above all in the light theme. Half state colour, half the text
// colour of the place keeps the hue and reads well in both themes (measured
// from pictures: at least 4.5:1 on every background the pages use).
function ink(theme, c) {
    var t = theme.textColor
    return Qt.rgba((c.r + t.r) / 2, (c.g + t.g) / 2, (c.b + t.b) / 2, 1)
}

// A highlight or state colour as a fill under the theme's text for
// highlighted things (the main button, the number of the current step).
// As it is, the highlight colour of Breeze gives that text 2.5:1; half of
// it and half the darker one of the place's text and background colour
// gives at least 4.5:1 in both themes, also when the fill is lightened
// under the pointer.
function deep(theme, c) {
    var t = theme.textColor, b = theme.backgroundColor
    var d = (t.r + t.g + t.b) < (b.r + b.g + b.b) ? t : b
    return Qt.rgba((c.r + d.r) / 2, (c.g + d.g) / 2, (c.b + d.b) / 2, 1)
}

// The colour of a check's summary on the dashboard. A check with problems
// is red, but one with medium problems only is orange, as the count in the
// header is. The root side sends no field for "has a high problem": the
// only place that says it is the summary it wrote ("1 high, 2 medium"),
// so this reads that English text. It is the one place that does; when the
// root side sends the highest severity of a check, use that here instead.
function summaryColor(theme, state, summary) {
    if (state === "ok" || state === "na") return theme.textColor
    if (state === "bad" && String(summary || "").indexOf(" high") < 0) return ink(theme, theme.neutralTextColor)
    return ink(theme, stateColor(theme, state))
}

// ---- the state of a check or an area ---------------------------------------
// Low findings (warn) read as blue information everywhere: icon, chip,
// summary and the header's "low" count.
function stateIcon(s) {
    return s === "bad" ? "dialog-error" : s === "warn" ? "dialog-information"
         : s === "reboot" ? "system-reboot" : (s === "ok" || s === "fixed") ? "dialog-ok-apply"
         : s === "note" ? "dialog-information" : s === "error" ? "dialog-error" : "dialog-cancel"
}
// The state in words, for screen readers and tool tips: the icon and the
// colour say it only to the eye.
function stateName(s) {
    return s === "bad" ? qsTr("Problems found") : s === "warn" ? qsTr("Minor findings")
         : s === "reboot" ? qsTr("Needs a reboot") : s === "ok" ? qsTr("No problems")
         : s === "fixed" ? qsTr("Fixed") : s === "note" ? qsTr("Has notes")
         : s === "error" ? qsTr("Could not be checked") : s === "skipped" ? qsTr("Skipped")
         : qsTr("Does not apply")
}
function stateColor(theme, s) {
    return s === "bad" ? theme.negativeTextColor
         : (s === "warn" || s === "reboot") ? theme.linkColor
         : (s === "ok" || s === "fixed") ? theme.positiveTextColor
         : theme.disabledTextColor
}

// ---- the severity of a finding ---------------------------------------------
function sevName(s) {
    return s === "high" ? qsTr("High severity") : s === "medium" ? qsTr("Medium severity")
         : s === "low" ? qsTr("Low severity") : qsTr("Information")
}
function sevColor(theme, s) {
    return s === "high" ? theme.negativeTextColor : s === "medium" ? theme.neutralTextColor
         : s === "low" ? theme.linkColor : theme.disabledTextColor
}

// ---- the risk of changing an item ------------------------------------------
// An unknown grade is shown as it came.
function riskText(r) {
    return r === "high" ? qsTr("High risk") : r === "medium" ? qsTr("Medium risk")
         : r === "low" ? qsTr("Low risk") : String(r || "")
}
function riskColor(theme, r) {
    return r === "high" ? theme.negativeTextColor : r === "medium" ? theme.neutralTextColor
         : r === "low" ? theme.positiveTextColor : theme.disabledTextColor
}
// The icon in front of a warning about an item: the warning itself is in
// the colour of all text, so that it can be read.
function riskIcon(r) {
    return r === "high" ? "dialog-error" : r === "medium" ? "dialog-warning" : "dialog-information"
}
// "Label, High risk" for screen readers; the label alone without a grade.
function riskLabel(label, r) {
    return r ? fill(qsTr("%1, %2"), [label, riskText(r)]) : String(label === undefined ? "" : label)
}
// The detail and the warning of an item as one description.
function describe(detail, warn) {
    return detail && warn ? fill(qsTr("%1. %2"), [detail, warn]) : String(detail || warn || "")
}
