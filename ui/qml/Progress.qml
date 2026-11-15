// Security Check - progress while the checks run: the one window besides
// the main one (Shell.qml), which is hidden meanwhile. The root side sends
// progress lines; ui/app.py sets these properties. Closing the window never
// stops the work: it hides the window when a tray icon can bring it back
// (the icon keeps the progress), else minimises it.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.ApplicationWindow {
    id: root
    title: qsTr("Security Check")
    width: Kirigami.Units.gridUnit * 30
    height: Kirigami.Units.gridUnit * 10
    minimumWidth: Kirigami.Units.gridUnit * 24
    minimumHeight: Kirigami.Units.gridUnit * 9
    pageStack.globalToolBar.style: Kirigami.ApplicationHeaderStyle.None

    property string iconSource: ""     // file URL of the app icon
    property string heading: qsTr("Checking your PC")
    property string label: qsTr("Starting…")
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
                    source: root.iconSource
                    implicitWidth: Kirigami.Units.iconSizes.huge
                    implicitHeight: implicitWidth
                    Accessible.ignored: true      // decoration; the heading says it
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    Kirigami.Heading {
                        Layout.fillWidth: true
                        text: root.heading
                        level: 2
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                    }
                    RowLayout {
                        QQC2.BusyIndicator {
                            visible: root.slow || root.percent < 0
                            running: visible
                            implicitWidth: Kirigami.Units.iconSizes.smallMedium
                            implicitHeight: implicitWidth
                            Accessible.name: qsTr("Working")
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
                    Accessible.name: root.percent >= 0 ? qsTr("Progress: %1%").arg(root.percent) : qsTr("Working")
                    Accessible.description: root.label
                    // A solid accent fill, so 40% and 90% are easy to tell
                    // apart in the light theme too.
                    background: Rectangle {
                        implicitHeight: Kirigami.Units.gridUnit * 0.6
                        radius: height / 2
                        color: Qt.alpha(Kirigami.Theme.textColor, 0.15)
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
                            id: sweep
                            width: parent.width * share; height: parent.height
                            radius: height / 2
                            color: Kirigami.Theme.linkColor
                            // One pass of the bar from side to side, in ms.
                            readonly property int sweepTime: 900
                            // How much of the track the moving bar covers.
                            readonly property real share: 0.3
                            SequentialAnimation on x {
                                running: bar.indeterminate; loops: Animation.Infinite
                                NumberAnimation { from: 0; to: bar.width * (1 - sweep.share); duration: sweep.sweepTime; easing.type: Easing.InOutQuad }
                                NumberAnimation { from: bar.width * (1 - sweep.share); to: 0; duration: sweep.sweepTime; easing.type: Easing.InOutQuad }
                            }
                        }
                    }
                }
                QQC2.Label {
                    visible: root.percent >= 0
                    text: qsTr("%1%").arg(root.percent)
                    Accessible.ignored: true      // the bar already says it
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
                    text: root.percent >= 0 ? qsTr("Nothing on this PC is changed while it checks.") : ""
                    opacity: 0.7
                    wrapMode: Text.Wrap
                }
                QQC2.Button {
                    visible: root.canHide
                    text: qsTr("Hide")
                    icon.name: "window-minimize"
                    onClicked: root.hide()
                    QQC2.ToolTip.text: qsTr("Keep working; the progress stays in the system tray.")
                    Accessible.description: QQC2.ToolTip.text
                    QQC2.ToolTip.visible: hovered
                }
            }
        }
    }
}
