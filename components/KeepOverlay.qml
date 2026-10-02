import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Ui
import qs.Commons

// "Keep these display settings?" on every screen while a change waits, so
// it is seen whichever display survived the change. The focused screen's
// card owns the keyboard. Revert is preselected: a blind Enter on a display
// that went dark brings the old settings back. K keeps.
//
// After the countdown the service reverts; if the shell itself is gone, the
// detached watchdog in bin/omnidisplay-ctl does.
Scope {
  id: root

  required property var service
  readonly property bool open: service.phase === "confirm" || service.phase === "keeping"
  property int selectedIndex: 0     // 0 = Revert, 1 = Keep

  onOpenChanged: if (open) selectedIndex = 0

  function choose(index) {
    if (index === 1) service.keep(!service.keepFailed)
    else service.revert()
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: win
        required property var modelData

        readonly property bool focusedScreen: Hyprland.focusedMonitor
          ? Hyprland.focusedMonitor.name === modelData.name
          : modelData === Quickshell.screens[0]

        screen: modelData
        visible: root.open
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "omnidisplay-keep"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.open && win.focusedScreen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors {
          top: true
          left: true
        }
        margins {
          top: Math.round((modelData.height - card.height) / 3)
          left: Math.round((modelData.width - card.width) / 2)
        }
        implicitWidth: card.width
        implicitHeight: card.height

        onVisibleChanged: if (visible && focusedScreen) Qt.callLater(function() { keys.forceActiveFocus() })

        Item {
          id: keys
          anchors.fill: parent
          focus: true
          Keys.onPressed: function(event) {
            if (!root.open) return
            if (event.key === Qt.Key_Escape) root.service.revert()
            else if (event.text === "k" || event.text === "K") root.choose(1)
            else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Tab
                     || event.key === Qt.Key_Backtab || event.text === "h" || event.text === "l")
              root.selectedIndex = root.selectedIndex === 0 ? 1 : 0
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)
              root.choose(root.selectedIndex)
            else return
            event.accepted = true
          }
        }

        BorderSurface {
          id: card
          width: Style.space(420)
          height: content.implicitHeight + card.contentTopInset + card.contentBottomInset
          color: Color.popups.background
          borderSpec: Border.flat(Color.accent, Math.max(1, Style.space(2)))
          padding: Style.space(20)
          radius: Style.cornerRadius

          Column {
            id: content
            x: card.contentLeftInset
            y: card.contentTopInset
            width: card.width - card.contentLeftInset - card.contentRightInset
            spacing: Style.space(12)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.service.keepFailed ? "Saving failed" : "Keep these display settings?"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.service.phase === "keeping"
                ? "Saving…"
                : (root.service.keepFailed
                   ? "Keep it live without saving, or revert. Reverting in " + root.service.remaining + " s."
                   : "Reverting to the previous settings in " + root.service.remaining + " s.")
              color: Qt.darker(Color.foreground, 1.3)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.service.problems
              Text {
                required property string modelData
                width: content.width
                textFormat: Text.PlainText
                text: "⚠ " + modelData
                color: Color.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            Rectangle {
              width: parent.width
              height: Math.max(3, Style.space(3))
              color: Util.alpha(Color.foreground, 0.12)
              Rectangle {
                width: parent.width * (1 - root.service.progress)
                height: parent.height
                color: Color.accent
              }
            }

            Row {
              spacing: Style.space(10)
              anchors.right: parent.right

              Button {
                text: "Revert"
                bordered: true
                hasCursor: root.selectedIndex === 0
                onClicked: root.choose(0)
                onHovered: function(h) { if (h) root.selectedIndex = 0 }
              }
              Button {
                text: root.service.keepFailed ? "Keep without saving" : "Keep  (K)"
                bordered: true
                active: true
                hasCursor: root.selectedIndex === 1
                onClicked: root.choose(1)
                onHovered: function(h) { if (h) root.selectedIndex = 1 }
              }
            }
          }
        }
      }
    }
  }
}
