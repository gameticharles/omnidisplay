import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Ui
import qs.Commons

// Identify: a large number and name in the corner of every screen, matching
// the numbers on the arrangement tiles. Click-through, never takes the
// keyboard, gone after a few seconds.
//
// After Krzysztof Golab Magalhaes' monitor-layout (MIT). See NOTICE.
Scope {
  id: root

  property var entries: []   // [{ output, number, label }]
  property bool showing: false

  function show(list) {
    entries = list || []
    showing = true
    hideTimer.restart()
  }

  function entryFor(output) {
    for (var i = 0; i < entries.length; i++) if (entries[i].output === output) return entries[i]
    return null
  }

  Timer {
    id: hideTimer
    interval: 3500
    onTriggered: root.showing = false
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: badge
        required property var modelData
        readonly property var entry: root.entryFor(modelData.name)

        screen: modelData
        visible: root.showing && !!entry
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "omnidisplay-identify"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}

        anchors {
          left: true
          bottom: true
        }
        margins {
          left: Style.space(40)
          bottom: Style.space(40)
        }
        implicitWidth: card.width
        implicitHeight: card.height

        BorderSurface {
          id: card
          width: row.implicitWidth + card.contentLeftInset + card.contentRightInset
          height: row.implicitHeight + card.contentTopInset + card.contentBottomInset
          color: Color.popups.background
          borderSpec: Border.flat(Color.accent, Math.max(1, Style.space(2)))
          padding: Style.space(24)
          radius: Style.cornerRadius

          Row {
            id: row
            x: card.contentLeftInset
            y: card.contentTopInset
            spacing: Style.space(24)

            Text {
              textFormat: Text.PlainText
              text: badge.entry ? String(badge.entry.number) : ""
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.display * 4
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              spacing: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                textFormat: Text.PlainText
                text: badge.entry ? badge.entry.label : ""
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.display
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                text: badge.modelData.name.toUpperCase()
                color: Qt.darker(Color.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
            }
          }
        }
      }
    }
  }
}
