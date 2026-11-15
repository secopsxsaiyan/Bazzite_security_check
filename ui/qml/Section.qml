// Security Check - a titled section of a page: a small heading with the
// content under it.
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

ColumnLayout {
    id: section
    property string title: ""
    default property alias content: body.data
    Layout.fillWidth: true
    spacing: Kirigami.Units.smallSpacing
    Kirigami.Heading {
        Layout.fillWidth: true
        level: 4; text: section.title; textFormat: Text.PlainText
        font.weight: Font.DemiBold
        Accessible.role: Accessible.Heading
    }
    ColumnLayout { id: body; Layout.fillWidth: true; spacing: Kirigami.Units.smallSpacing }
}
