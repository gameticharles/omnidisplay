import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Ui
import qs.Commons

// The arrangement on a whole screen, for desks with many or very different
// displays where the panel's canvas is small. Same draft, same Apply and
// countdown as the panel. Esc closes; nothing changes until Apply.
Scope {
  id: root

  required property var service

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: win
        required property var modelData
        readonly property bool focusedScreen: Hyprland.focusedMonitor
          ? Hyprland.focusedMonitor.name === modelData.name : modelData === Quickshell.screens[0]

        screen: modelData
        visible: root.service.fullArrangeOpen && focusedScreen && root.service.phase !== "confirm"
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "omnidisplay-arrange"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors { top: true; bottom: true; left: true; right: true }

        onVisibleChanged: if (visible) Qt.callLater(function() { keys.forceActiveFocus() })

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(Color.background, 0.98)
        }

        Item {
          id: keys
          anchors.fill: parent
          focus: true
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) root.service.fullArrangeOpen = false
            else if (event.text === "i") root.service.identify()
            else if (event.text === "a") root.service.applyDraft()
            else if (event.text === "r") root.service.resetDraft()
            else return
            event.accepted = true
          }
        }

        Column {
          anchors.fill: parent
          anchors.margins: Style.space(40)
          spacing: Style.space(16)

          Item {
            width: parent.width
            implicitHeight: Math.max(title.implicitHeight, buttons.implicitHeight)

            Column {
              id: title
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              Text {
                textFormat: Text.PlainText
                text: "Arrange displays"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.display
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                text: "Drag displays where they stand on your desk. i identify · a apply · r reset · Esc close"
                color: Qt.darker(Color.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }

            Row {
              id: buttons
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)
              Button { text: "Identify"; bordered: true; onClicked: root.service.identify() }
              Button { text: "Reset"; bordered: true; onClicked: root.service.resetDraft() }
              Button { text: "Apply"; bordered: true; active: root.service.dirty; onClicked: root.service.applyDraft() }
              Button { text: "Close"; bordered: true; onClicked: root.service.fullArrangeOpen = false }
            }
          }

          Repeater {
            model: root.service.messages.slice(0, 2)
            Text {
              required property var modelData
              textFormat: Text.PlainText
              text: modelData.text
              color: modelData.level === "error" ? Color.urgent : Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          MonitorCanvas {
            width: parent.width
            height: parent.height - title.implicitHeight - Style.space(80)
            service: root.service
            foreground: Color.foreground
            fontFamily: Style.font.family
          }
        }
      }
    }
  }
}
