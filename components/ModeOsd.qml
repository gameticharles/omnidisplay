import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Ui
import qs.Commons

// The laptop-mode switcher's on-screen display, like Windows' Win+P: the
// four modes in a row with the chosen one lit, on the focused screen, for
// a moment. Click-through; the keep countdown follows it.
Scope {
  id: root

  property var options: []      // [{ value, label }]
  property string current: ""
  property bool showing: false

  function show(list, value) {
    options = list || []
    current = value || ""
    showing = true
    hideTimer.restart()
  }

  Timer {
    id: hideTimer
    interval: 1600
    onTriggered: root.showing = false
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: win
        required property var modelData
        readonly property bool focusedScreen: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name === modelData.name : true

        screen: modelData
        visible: root.showing && focusedScreen
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "omnidisplay-mode"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}

        anchors {
          bottom: true
          left: true
        }
        margins {
          bottom: Style.space(120)
          left: Math.round((modelData.width - card.width) / 2)
        }
        implicitWidth: card.width
        implicitHeight: card.height

        BorderSurface {
          id: card
          width: row.implicitWidth + card.contentLeftInset + card.contentRightInset
          height: row.implicitHeight + card.contentTopInset + card.contentBottomInset
          color: Color.popups.background
          borderSpec: Border.flat(Color.popups.border, Math.max(1, Style.space(2)))
          padding: Style.space(16)
          radius: Style.cornerRadius

          Row {
            id: row
            x: card.contentLeftInset
            y: card.contentTopInset
            spacing: Style.space(10)

            Repeater {
              model: root.options

              Rectangle {
                id: tile
                required property var modelData
                readonly property bool lit: modelData.value === root.current
                width: Style.space(120)
                height: Style.space(84)
                radius: Style.cornerRadius
                color: lit ? Util.alpha(Color.accent, 0.22) : Util.alpha(Color.foreground, 0.05)
                border.width: lit ? Math.max(1, Style.space(2)) : 1
                border.color: lit ? Color.accent : Util.alpha(Color.foreground, 0.2)

                Column {
                  anchors.centerIn: parent
                  spacing: Style.space(6)
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: tile.modelData.value === "extend" ? "󰍺"
                        : tile.modelData.value === "mirror" ? "󰹑"
                        : tile.modelData.value === "external-only" ? "󰍹" : "󰌢"
                    color: tile.lit ? Color.accent : Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.display
                  }
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    textFormat: Text.PlainText
                    text: tile.modelData.label
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: tile.lit
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
