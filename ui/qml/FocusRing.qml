// Security Check - the keyboard focus ring of the controls drawn here (the
// main button, cards, rows, chips, the command block): one look everywhere,
// drawn around the control so it cannot be mistaken for a "switched on" or
// "selected" border. Put it inside the control's background (or the control)
// and name the control as its target.
import QtQuick
import org.kde.kirigami as Kirigami

Rectangle {
    id: ring
    // The control whose focus it shows. Controls say when the focus came
    // from the keyboard (visualFocus); other items (a text block) only
    // whether they have it.
    required property Item target
    // The corner radius of the shape it goes around.
    property real cornerRadius: Kirigami.Units.cornerRadius
    // How thick the ring is.
    readonly property real line: Math.max(2, Math.round(Kirigami.Units.smallSpacing / 2))
    // How far its outer edge is outside the control: the ring and a gap of
    // one pixel. 0 draws it just inside (rows that touch each other).
    property real outset: line + 1

    anchors.fill: parent
    anchors.margins: -outset
    radius: cornerRadius + outset
    color: "transparent"
    border.width: line
    border.color: Kirigami.Theme.focusColor
    visible: target.visualFocus !== undefined ? target.visualFocus : target.activeFocus
}
