// Security Check - progress while checks (or a fix) run. The root side
// sends progress lines; ui/app.py sets these properties. Closing the
// window never stops the work: it hides the window when a tray icon can
// bring it back (the icon keeps the progress), else minimises it.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.ApplicationWindow {
    id: root
    title: "Security Check"
    width: Kirigami.Units.gridUnit * 30
    height: Kirigami.Units.gridUnit * 10
    minimumWidth: Kirigami.Units.gridUnit * 24
    minimumHeight: Kirigami.Units.gridUnit * 9
    pageStack.globalToolBar.style: Kirigami.ApplicationHeaderStyle.None

    property string heading: (bridge.input && bridge.input.heading) || "Checking your PC"
    property string label: "Starting…"
    property string detail: ""
    property int percent: -1          // -1: no steps (a fix being applied)
    property bool slow: false          // a long step (malware scan): spinner
    property bool canHide: false       // set when a tray icon can bring it back

    // Closing never stops the work: it hides the window when the tray icon
    // can bring it back, else minimises it.
    onClosing: (close) => { close.accepted = false; if (root.canHide) root.hide(); else root.showMinimized() }

    pageStack.initialPage: Kirigami.Page {
        padding: Kirigami.Units.gridUnit
        titleDelegate: Item {}

        ColumnLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.largeSpacing

            RowLayout {
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Icon {
                    source: bridge.iconSource
                    implicitWidth: Kirigami.Units.iconSizes.huge
                    implicitHeight: implicitWidth
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    Kirigami.Heading { text: root.heading; level: 2; textFormat: Text.PlainText }
                    RowLayout {
                        QQC2.BusyIndicator {
                            visible: root.slow || root.percent < 0
                            running: visible
                            implicitWidth: Kirigami.Units.iconSizes.smallMedium
                            implicitHeight: implicitWidth
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: root.label
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            font.bold: true
                        }
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        visible: root.detail !== ""
                        text: root.detail
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        opacity: 0.75
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing
                QQC2.ProgressBar {
                    id: bar
                    Layout.fillWidth: true
                    from: 0; to: 100
                    value: Math.max(0, root.percent)
                    indeterminate: root.percent < 0
                    // A solid accent fill, so 40% and 90% are easy to tell
                    // apart in the light theme too.
                    background: Rectangle {
                        implicitHeight: Kirigami.Units.gridUnit * 0.6
                        radius: height / 2
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)
                    }
                    contentItem: Item {
                        implicitHeight: Kirigami.Units.gridUnit * 0.6
                        Rectangle {
                            visible: !bar.indeterminate
                            width: bar.visualPosition * parent.width; height: parent.height
                            radius: height / 2
                            color: Kirigami.Theme.linkColor
                        }
                        Rectangle {
                            visible: bar.indeterminate
                            width: parent.width * 0.3; height: parent.height
                            radius: height / 2
                            color: Kirigami.Theme.linkColor
                            SequentialAnimation on x {
                                running: bar.indeterminate; loops: Animation.Infinite
                                NumberAnimation { from: 0; to: bar.width * 0.7; duration: 900; easing.type: Easing.InOutQuad }
                                NumberAnimation { from: bar.width * 0.7; to: 0; duration: 900; easing.type: Easing.InOutQuad }
                            }
                        }
                    }
                }
                QQC2.Label {
                    visible: root.percent >= 0
                    text: root.percent + "%"
                    font.bold: true
                    Layout.minimumWidth: Kirigami.Units.gridUnit * 2.5
                    horizontalAlignment: Text.AlignRight
                }
            }

            Item { Layout.fillHeight: true; Layout.maximumHeight: Kirigami.Units.largeSpacing }

            RowLayout {
                Layout.fillWidth: true
                QQC2.Label {
                    Layout.fillWidth: true
                    text: root.percent >= 0 ? "Nothing on this PC is changed while it checks." : ""
                    opacity: 0.7
                    wrapMode: Text.Wrap
                }
                QQC2.Button {
                    visible: root.canHide
                    text: "Hide"
                    icon.name: "window-minimize"
                    onClicked: root.hide()
                    QQC2.ToolTip.text: "Keep working; the progress stays in the system tray."
                    QQC2.ToolTip.visible: hovered
                }
            }
        }
    }
}
