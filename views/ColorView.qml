import QtQuick
import qs.Ui
import qs.Commons
import "../lib/Model.js" as Model
import "../lib/Lua.js" as Lua
import "../components"

// The Colour tab: colour management (HDR included), bit depth and SDR
// controls per display, what the panel's EDID says it can do, and contrast
// and input source over DDC/CI for external monitors. Colour settings go
// through the countdown like everything else; DDC values are live hardware
// state and apply at once.
Column {
  id: view

  required property var panel
  readonly property var service: panel.service
  readonly property color fg: panel.foreground
  readonly property string ff: panel.fontFamily
  readonly property color dim: panel.dim

  readonly property var onDisplays: service.draft.filter(function(e) { return e.enabled !== false })
  readonly property var entry: {
    var e = service.selectedEntry
    return e && e.enabled !== false ? e : (onDisplays.length ? onDisplays[0] : null)
  }
  readonly property var live: entry ? Model.entryByName(service.monitors, entry.name) : null
  readonly property var caps: entry ? service.edidCaps[entry.name] : null
  readonly property bool capsKnown: !!caps && !caps.missing
  readonly property bool hdrMode: !!entry && (entry.cmSet === "hdr" || entry.cmSet === "hdredid"
                                             || (!entry.cmSet && !!live && /hdr/.test(live.cm)))
  readonly property var ddc: entry ? service.ddcValues[entry.name] : null

  width: parent ? parent.width : 0
  spacing: Style.space(12)

  onEntryChanged: if (entry) service.loadEdid(entry.name)
  Component.onCompleted: { if (entry) service.loadEdid(entry.name); service.detectDdc() }

  function handleText(t) {
    if (t === "a") service.applyDraft()
    else if (t === "r") service.resetDraft()
  }

  // Which display
  ButtonGroup {
    visible: view.onDisplays.length > 1
    width: parent.width
    options: view.onDisplays.map(function(e) { return { value: e.name, label: e.name } })
    value: view.entry ? view.entry.name : ""
    foreground: view.fg
    fontFamily: view.ff
    fontSize: Style.font.caption
    focusable: false
    onChanged: function(v) { view.service.select(v) }
  }

  Section {
    visible: !!view.entry
    separator: false
    title: view.entry ? ("COLOUR · " + Model.displayLabel(view.entry)).toUpperCase() : ""
    // Requested next to what Hyprland actually uses: a preset the panel
    // cannot do falls back silently otherwise.
    trailing: view.live ? (view.entry && view.entry.cmSet && view.entry.cmSet !== view.live.cm
                           ? "ASKED " + view.entry.cmSet.toUpperCase() + " · NOW " : "NOW ")
                          + view.live.cm.toUpperCase() + " · " + view.live.liveBitdepth + "-BIT" : ""
    foreground: view.fg
    fontFamily: view.ff

    FieldRow {
      label: "Colour preset"
      hint: view.capsKnown && !view.caps.hdr ? "This panel does not report HDR" : ""
      foreground: view.fg
      fontFamily: view.ff
      Dropdown {
        width: parent.width
        showLabel: false
        foreground: view.fg
        fontFamily: view.ff
        value: view.entry ? view.entry.cmSet : ""
        options: [{ value: "", label: "Default (no rule)" }].concat(Model.CM_PRESETS.filter(function(p) {
          if (!view.capsKnown) return true
          if ((p.value === "hdr" || p.value === "hdredid") && !view.caps.hdr) return false
          return true
        }))
        onChanged: function(v) {
          view.service.setCm(view.entry.name, v)
          // Hyprland's default SDR white level is dim in HDR; start from the
          // BT.2408 reference, as Windows and Vista do.
          if ((v === "hdr" || v === "hdredid") && !(view.entry.sdrbrightness > 0)) view.service.setSdr(view.entry.name, 1.0, 1.0)
        }
      }
    }

    FieldRow {
      label: "Bit depth"
      hint: view.capsKnown && view.caps.bitsPerColor ? "Panel: " + view.caps.bitsPerColor + "-bit" : ""
      foreground: view.fg
      fontFamily: view.ff
      ButtonGroup {
        anchors.right: parent.right
        options: [{ value: "0", label: "Default" }, { value: "8", label: "8-bit" }, { value: "10", label: "10-bit" }]
        value: view.entry ? String(view.entry.bitdepth || 0) : "0"
        foreground: view.fg
        fontFamily: view.ff
        fontSize: Style.font.caption
        focusable: false
        onChanged: function(v) { view.service.setBitdepth(view.entry.name, Number(v)) }
      }
    }

    FieldRow {
      label: "Adaptive sync"
      hint: view.capsKnown && view.caps.vrrMin ? view.caps.vrrMin + "–" + view.caps.vrrMax + " Hz" : ""
      foreground: view.fg
      fontFamily: view.ff
      Dropdown {
        width: parent.width
        showLabel: false
        foreground: view.fg
        fontFamily: view.ff
        value: view.entry ? String(view.entry.vrr) : "-1"
        options: Model.VRR_MODES.map(function(m) { return { value: String(m.value), label: m.label } })
        onChanged: function(v) { view.service.setVrr(view.entry.name, Number(v)) }
      }
    }

    FieldRow {
      label: "ICC profile"
      hint: view.entry && view.entry.icc ? view.entry.icc.split("/").pop() : "Path to an .icc or .icm file"
      foreground: view.fg
      fontFamily: view.ff
      Row {
        width: parent.width
        spacing: Style.space(6)
        TextField {
          id: iccField
          width: parent.width - iccSet.width - parent.spacing
          placeholderText: view.entry && view.entry.icc ? view.entry.icc : "/home/you/profiles/monitor.icc"
          foreground: view.fg
          onActiveFocusChanged: view.panel.textEditing = activeFocus
          onAccepted: iccSet.clicked()
          Keys.onEscapePressed: { text = ""; focus = false; view.panel.textEditing = false }
        }
        Button {
          id: iccSet
          text: iccField.text === "" && view.entry && view.entry.icc ? "Clear" : "Set"
          bordered: true
          fontSize: Style.font.caption
          foreground: view.fg
          fontFamily: view.ff
          onClicked: {
            var path = iccField.text.trim()
            if (path !== "" && !/^\/.+\.(icc|icm)$/i.test(path)) { view.service.say("error", "Use the full path to an .icc or .icm file"); return }
            view.service.setIcc(view.entry.name, path)
            iccField.text = ""
            iccField.focus = false
            view.panel.textEditing = false
          }
        }
      }
    }

    Column {
      visible: view.hdrMode
      width: parent.width
      spacing: Style.space(4)
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "SDR content brightness  " + Model.roundTo(sdrB.dragging ? sdrB.liveValue : (view.entry && view.entry.sdrbrightness > 0 ? view.entry.sdrbrightness : 1), 2) + "×"
        color: view.fg
        font.family: view.ff
        font.pixelSize: Style.font.body
      }
      PanelSlider {
        id: sdrB
        bar: view.panel.bar
        width: parent.width
        minimum: 0.5
        maximum: 2.0
        step: 0.05
        value: view.entry && view.entry.sdrbrightness > 0 ? view.entry.sdrbrightness : 1
        onReleased: function(v) { view.service.setSdr(view.entry.name, Model.roundTo(v, 2), undefined) }
      }
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "SDR saturation  " + Model.roundTo(sdrS.dragging ? sdrS.liveValue : (view.entry && view.entry.sdrsaturation > 0 ? view.entry.sdrsaturation : 1), 2) + "×"
        color: view.fg
        font.family: view.ff
        font.pixelSize: Style.font.body
      }
      PanelSlider {
        id: sdrS
        bar: view.panel.bar
        width: parent.width
        minimum: 0.5
        maximum: 1.5
        step: 0.05
        value: view.entry && view.entry.sdrsaturation > 0 ? view.entry.sdrsaturation : 1
        onReleased: function(v) { view.service.setSdr(view.entry.name, undefined, Model.roundTo(v, 2)) }
      }
    }

    Row {
      anchors.right: parent.right
      spacing: Style.space(8)
      Button {
        text: "Reset"
        bordered: true
        foreground: view.fg
        fontFamily: view.ff
        onClicked: view.service.resetDraft()
      }
      Button {
        text: "Apply"
        bordered: true
        active: view.service.dirty
        foreground: view.fg
        fontFamily: view.ff
        onClicked: view.service.applyDraft()
      }
    }
  }

  // HDR details: for panels Hyprland misreads, and luminance the EDID gets
  // wrong. Empty means Hyprland's default (from the EDID where it has one).
  Section {
    id: hdrSection
    property bool open: view.hdrMode
    visible: !!view.entry
    title: "HDR DETAILS"
    trailing: hdrSection.open ? "" : "SHOW"
    foreground: view.fg
    fontFamily: view.ff

    Text {
      visible: !hdrSection.open
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Force HDR on a panel Hyprland misreads, set the SDR white level, override luminance… (click to show)"
      color: view.dim
      font.family: view.ff
      font.pixelSize: Style.font.caption
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: hdrSection.open = true }
    }

    Repeater {
      model: hdrSection.open ? [
        { key: "supportsHdr", label: "HDR support", kind: "force" },
        { key: "supportsWideColor", label: "Wide colour support", kind: "force" }
      ] : []
      FieldRow {
        required property var modelData
        label: modelData.label
        hint: "Force when the EDID is wrong"
        foreground: view.fg
        fontFamily: view.ff
        ButtonGroup {
          anchors.right: parent.right
          options: [{ value: "", label: "Auto" }, { value: "0", label: "Off" }, { value: "1", label: "On" }]
          value: view.entry && view.entry[modelData.key] !== null && view.entry[modelData.key] !== undefined && view.entry[modelData.key] >= 0
                 ? String(view.entry[modelData.key]) : ""
          foreground: view.fg
          fontFamily: view.ff
          fontSize: Style.font.caption
          focusable: false
          onChanged: function(v) { view.service.setHdrField(view.entry.name, modelData.key, v === "" ? null : Number(v)) }
        }
      }
    }

    Repeater {
      model: hdrSection.open ? [
        { key: "sdrMaxLuminance", label: "SDR white level", unit: "nits", hint: "203 is the BT.2408 reference", edid: 0 },
        { key: "sdrMinLuminance", label: "SDR black level", unit: "nits", hint: "", edid: 0 },
        { key: "maxLuminance", label: "Peak luminance", unit: "nits", hint: "EDID", edid: view.capsKnown ? view.caps.maxLuminance : 0 },
        { key: "maxAvgLuminance", label: "Full-screen luminance", unit: "nits", hint: "EDID", edid: view.capsKnown ? view.caps.maxAvgLuminance : 0 },
        { key: "minLuminance", label: "Black luminance", unit: "nits", hint: "EDID", edid: view.capsKnown ? view.caps.minLuminance : 0 }
      ] : []
      FieldRow {
        id: lumRow
        required property var modelData
        readonly property var current: view.entry ? view.entry[modelData.key] : null
        label: modelData.label
        hint: (current !== null && current !== undefined ? "Set: " + current + " " + modelData.unit
               : (modelData.edid ? "EDID says " + modelData.edid + " " + modelData.unit : "Default"))
              + (modelData.hint && modelData.hint !== "EDID" ? " · " + modelData.hint : "")
        foreground: view.fg
        fontFamily: view.ff
        Row {
          width: parent.width
          spacing: Style.space(6)
          TextField {
            id: lumField
            width: parent.width - lumSet.width - lumClear.width - parent.spacing * 2
            placeholderText: lumRow.modelData.edid ? String(lumRow.modelData.edid) : "nits"
            foreground: view.fg
            onActiveFocusChanged: view.panel.textEditing = activeFocus
            onAccepted: lumSet.clicked()
            Keys.onEscapePressed: { text = ""; focus = false; view.panel.textEditing = false }
          }
          Button {
            id: lumSet
            text: "Set"
            bordered: true
            fontSize: Style.font.caption
            foreground: view.fg
            fontFamily: view.ff
            onClicked: {
              var t = lumField.text.trim() || (lumRow.modelData.edid ? String(lumRow.modelData.edid) : "")
              if (!/^\d+(\.\d+)?$/.test(t)) { view.service.say("error", "Type a number of nits"); return }
              view.service.setHdrField(view.entry.name, lumRow.modelData.key, Number(t))
              lumField.text = ""
              lumField.focus = false
              view.panel.textEditing = false
            }
          }
          PanelActionButton {
            id: lumClear
            iconText: "󰅖"
            tooltipText: "Back to the default"
            foreground: view.fg
            onClicked: view.service.setHdrField(view.entry.name, lumRow.modelData.key, null)
          }
        }
      }
    }

    FieldRow {
      visible: hdrSection.open
      label: "SDR transfer"
      hint: "How SDR content is decoded in HDR"
      foreground: view.fg
      fontFamily: view.ff
      Dropdown {
        width: parent.width
        showLabel: false
        foreground: view.fg
        fontFamily: view.ff
        value: view.entry ? view.entry.sdrEotf : ""
        options: [{ value: "", label: "Default (no rule)" }, { value: "default", label: "Default" }, { value: "auto", label: "Auto" },
                  { value: "srgb", label: "sRGB" }, { value: "gamma22", label: "Gamma 2.2" }, { value: "gamma22force", label: "Gamma 2.2 (forced)" }]
        onChanged: function(v) { view.service.setSdrEotf(view.entry.name, v) }
      }
    }

    // Calibrating by eye: a test pattern fullscreen, then what was seen.
    Column {
      visible: hdrSection.open && !!view.live && /^hdr/.test(view.live.cm)
      width: parent.width
      spacing: Style.space(6)
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: view.service.calibrating
          ? "Showing the " + view.service.calibrating + " pattern: look, then press q."
          : "Calibrate by eye: each test fills the screen until you press q. Turn off the TV's own tone mapping and dynamic contrast first; if the control square at the bottom right shows, the TV is altering the picture."
        color: view.dim
        font.family: view.ff
        font.pixelSize: Style.font.caption
      }
      Row {
        spacing: Style.space(6)
        Repeater {
          model: [{ k: "peak", l: "Peak" }, { k: "full", l: "Full screen" }, { k: "black", l: "Black level" }]
          Button {
            required property var modelData
            text: modelData.l
            bordered: true
            fontSize: Style.font.caption
            foreground: view.fg
            fontFamily: view.ff
            onClicked: view.service.calibrate(modelData.k, view.entry.name)
          }
        }
      }
      Text {
        visible: view.service.calibrated !== ""
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: view.service.calibrated === "black"
          ? "Which was the brightest square that still looked black?"
          : "Which was the first square that vanished into its frame?"
        color: view.fg
        font.family: view.ff
        font.pixelSize: Style.font.body
      }
      Flow {
        visible: view.service.calibrated !== ""
        width: parent.width
        spacing: Style.space(4)
        Repeater {
          model: view.service.calibrated !== "" ? view.service.calibrationLevels : []
          Button {
            required property var modelData
            text: String(modelData)
            bordered: true
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.sm
            foreground: view.fg
            fontFamily: view.ff
            onClicked: view.service.answerCalibration(view.entry.name, view.service.calibrated, modelData)
          }
        }
      }
    }

    Row {
      visible: hdrSection.open
      anchors.right: parent.right
      spacing: Style.space(8)
      Button {
        visible: !!view.live && /^hdr/.test(view.live.cm)
        text: "Re-send HDR"
        tooltipText: "For a panel that dropped out of HDR after sleep"
        bordered: true
        fontSize: Style.font.caption
        foreground: view.fg
        fontFamily: view.ff
        onClicked: view.service.resendHdr()
      }
      Button {
        text: "Apply"
        bordered: true
        active: view.service.dirty
        foreground: view.fg
        fontFamily: view.ff
        onClicked: view.service.applyDraft()
      }
    }
  }

  // Options for every display, applied and kept like the rest.
  Section {
    title: "ALL DISPLAYS"
    trailing: "APPLY TO TRY · KEEP TO SAVE"
    foreground: view.fg
    fontFamily: view.ff

    Repeater {
      model: Lua.GLOBAL_OPTIONS
      FieldRow {
        id: globalRow
        required property var modelData
        readonly property var current: view.service.draftGlobals[modelData.key] !== undefined
          ? view.service.draftGlobals[modelData.key] : view.service.liveGlobals[modelData.key]
        label: modelData.label
        hint: modelData.hint
        labelRatio: 0.5
        foreground: view.fg
        fontFamily: view.ff
        ToggleSwitch {
          visible: globalRow.modelData.type === "bool"
          anchors.right: parent.right
          checked: globalRow.current === true
          foreground: view.fg
          onToggled: view.service.setGlobal(globalRow.modelData.key, !(globalRow.current === true))
        }
        Dropdown {
          visible: globalRow.modelData.type !== "bool"
          width: parent.width
          showLabel: false
          foreground: view.fg
          fontFamily: view.ff
          value: globalRow.current === undefined || globalRow.current === null ? "" : String(globalRow.current)
          options: globalRow.modelData.type === "bool" ? [] : globalRow.modelData.values.map(function(v, i) {
            return { value: String(v), label: globalRow.modelData.labels[i] }
          })
          onChanged: function(v) { view.service.setGlobal(globalRow.modelData.key, globalRow.modelData.type === "string" ? v : Number(v)) }
        }
      }
    }

    Row {
      anchors.right: parent.right
      spacing: Style.space(8)
      Button {
        text: "Apply"
        bordered: true
        active: view.service.dirty
        foreground: view.fg
        fontFamily: view.ff
        onClicked: view.service.applyDraft()
      }
    }
  }

  Section {
    visible: !!view.entry
    title: "WHAT THE PANEL REPORTS"
    trailing: view.caps === null ? "READING…" : (view.caps && view.caps.missing === "edid-decode-missing" ? "INSTALL edid-decode" : "")
    foreground: view.fg
    fontFamily: view.ff

    Repeater {
      model: view.capsKnown ? Model.capabilityLines(view.caps) : []
      FieldRow {
        required property var modelData
        label: modelData.label
        foreground: view.fg
        fontFamily: view.ff
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: modelData.value
          color: view.fg
          font.family: view.ff
          font.pixelSize: Style.font.body
        }
      }
    }
    Text {
      visible: !!view.caps && !!view.caps.missing
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: view.caps && view.caps.missing === "edid-decode-missing"
        ? "Capabilities need edid-decode (package v4l-utils)."
        : "This output has no EDID (virtual and some docked outputs)."
      color: view.dim
      font.family: view.ff
      font.pixelSize: Style.font.caption
    }
  }

  Section {
    visible: !!view.entry && !view.entry.internal
    title: "MONITOR CONTROLS (DDC/CI)"
    trailing: view.service.ddcBuses[view.entry ? view.entry.name : ""] === undefined ? (view.service.useDdc ? "NOT AVAILABLE" : "OFF IN SETTINGS") : ""
    foreground: view.fg
    fontFamily: view.ff

    Column {
      visible: !!view.ddc && view.ddc.contrast >= 0
      width: parent.width
      spacing: Style.space(4)
      Text {
        textFormat: Text.PlainText
        text: "Contrast  " + (view.ddc ? Math.round(contrast.dragging ? contrast.liveValue : view.ddc.contrast) : "")
        color: view.fg
        font.family: view.ff
        font.pixelSize: Style.font.body
      }
      PanelSlider {
        id: contrast
        bar: view.panel.bar
        width: parent.width
        minimum: 0
        maximum: view.ddc ? view.ddc.contrastMax : 100
        step: 1
        integer: true
        value: view.ddc ? view.ddc.contrast : 50
        onReleased: function(v) { view.service.setDdc(view.entry.name, "12", Math.round(v)) }
      }
    }

    FieldRow {
      visible: !!view.ddc
      label: "Input source"
      hint: "Switching moves the monitor to another computer or device"
      foreground: view.fg
      fontFamily: view.ff
      Dropdown {
        width: parent.width
        showLabel: false
        foreground: view.fg
        fontFamily: view.ff
        value: view.ddc ? String(view.ddc.input || "").replace(/^x/, "0x") : ""
        options: [
          { value: "0x0f", label: "DisplayPort 1" }, { value: "0x10", label: "DisplayPort 2" },
          { value: "0x11", label: "HDMI 1" }, { value: "0x12", label: "HDMI 2" },
          { value: "0x1b", label: "USB-C" }, { value: "0x03", label: "DVI 1" }, { value: "0x01", label: "VGA" }
        ]
        onChanged: function(v) { view.service.setDdc(view.entry.name, "60", v) }
      }
    }

    FieldRow {
      visible: !!view.ddc && !!view.ddc.preset
      label: "Colour preset (monitor)"
      hint: "The monitor's own picture preset"
      foreground: view.fg
      fontFamily: view.ff
      Dropdown {
        width: parent.width
        showLabel: false
        foreground: view.fg
        fontFamily: view.ff
        value: view.ddc ? String(view.ddc.preset || "").replace(/^x/, "0x") : ""
        options: [
          { value: "0x01", label: "sRGB" }, { value: "0x02", label: "Native" }, { value: "0x04", label: "5000 K" },
          { value: "0x05", label: "6500 K" }, { value: "0x06", label: "7500 K" }, { value: "0x08", label: "9300 K" },
          { value: "0x0b", label: "User 1" }, { value: "0x0c", label: "User 2" }, { value: "0x0d", label: "User 3" }
        ]
        onChanged: function(v) { view.service.setDdc(view.entry.name, "14", v) }
      }
    }

    Text {
      visible: view.service.ddcBuses[view.entry ? view.entry.name : ""] === undefined
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Contrast and input switching need DDC/CI: ddcutil installed, the i2c-dev module loaded, and DDC/CI enabled in the monitor's own menu. Brightness works through Omarchy's brightness command either way."
      color: view.dim
      font.family: view.ff
      font.pixelSize: Style.font.caption
    }
  }
}
