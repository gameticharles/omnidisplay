import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import "../lib/Model.js" as Model
import "../lib/Profiles.js" as Profiles
import "../components"

// The Display tab: what the built-in widget offers (brightness, text size,
// scale, turning displays on and off), done for every display, plus the
// laptop modes, night light and presentation mode. Scale, modes and on/off
// go through the keep-or-revert countdown.
Column {
  id: view

  required property var panel
  readonly property var service: panel.service
  readonly property color fg: panel.foreground
  readonly property string ff: panel.fontFamily
  readonly property color dim: panel.dim

  width: parent ? parent.width : 0
  spacing: Style.space(12)

  readonly property var onDisplays: service.monitors.filter(function(m) { return m.enabled !== false })
  readonly property var focused: service.focusedMonitor
  property bool allDisplays: false

  // The layout first, as screens on a stage (drag here or in Arrange).
  MonitorCanvas {
    width: parent.width
    height: Style.space(130)
    service: view.service
    notes: view.service.displayNotes
    foreground: view.fg
    fontFamily: view.ff
  }

  // ------------------------------------------------------------ brightness

  Section {
    title: "BRIGHTNESS"
    separator: false
    foreground: view.fg
    fontFamily: view.ff

    Repeater {
      model: view.onDisplays

      Column {
        id: brightRow
        required property var modelData
        readonly property var value: view.service.brightness[modelData.name]
        // In HDR the backlight does nothing visible: the slider sets SDR brightness.
        readonly property bool hdr: view.service.inHdr(modelData)
        width: view.width
        spacing: Style.space(4)

        Item {
          width: parent.width
          implicitHeight: nameText.implicitHeight
          Text {
            id: nameText
            textFormat: Text.PlainText
            text: Model.displayLabel(brightRow.modelData) + "  ·  " + brightRow.modelData.name
            color: view.fg
            font.family: view.ff
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            width: parent.width - pct.width - Style.space(10)
          }
          Text {
            id: pct
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            textFormat: Text.PlainText
            text: brightRow.hdr
              ? "SDR " + Model.roundTo(sdrSlider.dragging ? sdrSlider.liveValue : brightRow.modelData.sdrBrightness, 2) + "×"
              : (brightRow.value === undefined ? "…" : brightRow.value < 0 ? "fixed" : Math.round(slider.dragging ? slider.liveValue : brightRow.value) + "%")
            color: view.dim
            font.family: view.ff
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        PanelSlider {
          id: sdrSlider
          visible: brightRow.hdr
          bar: view.panel.bar
          width: parent.width
          minimum: 0.5
          maximum: 2
          step: 0.05
          value: brightRow.modelData.sdrBrightness || 1
          onReleased: function(v) { view.service.setSdrBrightnessNow(brightRow.modelData.name, v) }
        }

        PanelSlider {
          id: slider
          visible: !brightRow.hdr && brightRow.value !== undefined && brightRow.value >= 0
          bar: view.panel.bar
          width: parent.width
          minimum: 1
          maximum: 100
          step: 1
          integer: true
          value: brightRow.value >= 0 ? brightRow.value : 50
          onReleased: function(v) { view.service.setBacklight(brightRow.modelData.name, v) }
        }
      }
    }
  }

  // ------------------------------------------------------------- text size

  readonly property var textStops: [9, 10, 11, 12, 14, 16, 20]
  property int textPreview: -1

  function nearestStop(px) {
    var best = 0
    for (var i = 0; i < textStops.length; i++) if (Math.abs(textStops[i] - px) < Math.abs(textStops[best] - px)) best = i
    return best
  }

  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      if (view.textPreview >= 0 && view.nearestStop(Style.font.baseSize) === view.textPreview) view.textPreview = -1
    }
  }

  Section {
    title: "TEXT SIZE"
    trailing: (view.textPreview >= 0 ? view.textStops[view.textPreview] : Style.font.baseSize) + "px"
    foreground: view.fg
    fontFamily: view.ff

    PanelSlider {
      bar: view.panel.bar
      width: parent.width
      minimum: 0
      maximum: view.textStops.length - 1
      step: 1
      integer: true
      tickCount: view.textStops.length
      value: view.textPreview >= 0 ? view.textPreview : view.nearestStop(Style.font.baseSize)
      onReleased: function(v) {
        view.textPreview = Math.round(v)
        Quickshell.execDetached(["omarchy-display-text-size", String(view.textStops[Math.round(v)])])
        if (view.panel.setting("terminalFontOverrides", false)) termTimer.restart()
      }
    }

    Timer { id: termTimer; interval: 800; onTriggered: view.service.readTerminalFonts() }

    Repeater {
      model: view.panel.setting("terminalFontOverrides", false) ? view.service.terminalFonts : []
      FieldRow {
        required property var modelData
        label: modelData.terminal
        foreground: view.fg
        fontFamily: view.ff
        Row {
          anchors.right: parent.right
          spacing: Style.space(6)
          PanelActionButton {
            iconText: "󰍴"
            tooltipText: "Smaller"
            foreground: view.fg
            onClicked: view.service.setTerminalFont(modelData.terminal, Math.max(6, (modelData.size || 9) - 0.5))
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: modelData.size === null ? "?" : modelData.size + " pt"
            color: view.fg
            font.family: view.ff
            font.pixelSize: Style.font.body
          }
          PanelActionButton {
            iconText: "󰐕"
            tooltipText: "Larger"
            foreground: view.fg
            onClicked: view.service.setTerminalFont(modelData.terminal, Math.min(40, (modelData.size || 9) + 0.5))
          }
        }
      }
    }

    Component.onCompleted: if (view.panel.setting("terminalFontOverrides", false)) view.service.readTerminalFonts()
  }

  // ----------------------------------------------------------------- scale

  readonly property var scaleTarget: allDisplays ? null : focused
  readonly property var scaleValues: focused ? Model.availableScales(Model.SCALE_PRESETS, focused.width, focused.height) : Model.SCALE_PRESETS

  Section {
    title: "SCALE"
    trailing: view.allDisplays ? "ALL DISPLAYS" : (view.focused && view.service.enabledCount > 1 ? view.focused.name : "")
    foreground: view.fg
    fontFamily: view.ff

    Grid {
      id: scaleGrid
      width: parent.width
      columns: view.scaleValues.length
      spacing: Style.spacing.xs
      readonly property real cellWidth: (width - spacing * (columns - 1)) / Math.max(1, columns)

      Repeater {
        model: view.scaleValues
        Button {
          required property string modelData
          width: scaleGrid.cellWidth
          text: (view.focused ? Model.normalizeScale(Model.cleanScale(modelData, view.focused.width, view.focused.height)) : modelData) + "x"
          fontSize: Style.font.caption
          foreground: view.fg
          fontFamily: view.ff
          horizontalPadding: Style.spacing.sm
          bordered: true
          active: !!view.focused && Model.sameScale(view.focused.scale, Model.cleanScale(modelData, view.focused.width, view.focused.height))
          onClicked: {
            if (view.allDisplays) view.service.universalScaleNow(modelData)
            else if (view.focused) view.service.scaleNow(view.focused.name, modelData)
          }
        }
      }
    }

    Toggle {
      visible: view.service.enabledCount > 1
      width: parent.width
      label: "Same scale on every display"
      description: "Each display gets the closest clean scale for its resolution."
      checked: view.allDisplays
      foreground: view.fg
      fontFamily: view.ff
      onClicked: view.allDisplays = !view.allDisplays
    }
  }

  // ---------------------------------------------------------- laptop modes

  Section {
    visible: view.service.hasLaptopChoice
    title: "WITH AN EXTERNAL DISPLAY"
    trailing: "SUPER+P STYLE"
    foreground: view.fg
    fontFamily: view.ff

    ButtonGroup {
      width: parent.width
      options: Profiles.LAPTOP_MODES.map(function(m) { return { value: m, label: Profiles.laptopModeLabel(m) } })
      value: view.service.laptopMode
      foreground: view.fg
      fontFamily: view.ff
      fontSize: Style.font.caption
      focusable: false
      onChanged: function(v) { view.service.laptopModeNow(v) }
    }
  }

  // -------------------------------------------------------------- displays

  Section {
    visible: view.service.monitors.length > 1
    title: "DISPLAYS"
    foreground: view.fg
    fontFamily: view.ff

    Repeater {
      model: view.service.monitors
      FieldRow {
        required property var modelData
        label: Model.displayLabel(modelData)
        hint: modelData.name + (modelData.enabled === false ? " · off" : modelData.mirror ? " · mirrors " + modelData.mirror : " · " + Model.modeLabel(modelData))
        labelRatio: 0.78
        foreground: view.fg
        fontFamily: view.ff
        ToggleSwitch {
          anchors.right: parent.right
          checked: modelData.enabled !== false
          interactive: modelData.enabled === false || view.service.enabledCount > 1
          foreground: view.fg
          onToggled: view.service.toggleDisplayNow(modelData.name)
        }
      }
    }
  }

  // ------------------------------------------------------- night light etc.

  Section {
    title: "COMFORT"
    foreground: view.fg
    fontFamily: view.ff

    FieldRow {
      visible: view.service.nightState.available !== false
      label: "Night light"
      hint: view.service.nightState.enabled ? view.service.nightState.temperature + " K" : "Off"
      foreground: view.fg
      fontFamily: view.ff
      ToggleSwitch {
        anchors.right: parent.right
        checked: !!view.service.nightState.enabled
        foreground: view.fg
        onToggled: view.service.setNight(!view.service.nightState.enabled)
      }
    }

    PanelSlider {
      visible: !!view.service.nightState.enabled
      bar: view.panel.bar
      width: parent.width
      minimum: 2500
      maximum: 6000
      step: 100
      integer: true
      value: view.service.nightState.temperature || 4000
      onMoved: function(v) { view.service.setTemperature(v) }
      onReleased: function(v) { view.service.setTemperature(v) }
    }

    FieldRow {
      label: "Presentation mode"
      hint: view.service.presenting ? "Screen stays awake, notifications are quiet" : "Off"
      foreground: view.fg
      fontFamily: view.ff
      ToggleSwitch {
        anchors.right: parent.right
        checked: view.service.presenting
        foreground: view.fg
        onToggled: view.service.setPresenting(!view.service.presenting)
      }
    }
  }
}
