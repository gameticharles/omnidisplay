import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import "../lib/Model.js" as Model
import "../lib/Layout.js" as Layout
import "../components"

// The Arrange tab: the canvas, and the selected display's settings below it.
// Edits stay in the draft until Apply, which goes through the countdown.
//
// Keys: h/l choose a display, Enter picks it up and puts it down, h/j/k/l
// move a picked-up display 100 px (H/J/K/L 10 px), + and - step the scale,
// o rotates a quarter turn, e turns the display on or off, a applies,
// r resets, p shows the plan, i identifies.
Column {
  id: view

  required property var panel
  readonly property var service: panel.service
  readonly property color fg: panel.foreground
  readonly property string ff: panel.fontFamily
  readonly property color dim: panel.dim

  readonly property var entry: service.selectedEntry
  readonly property var liveEntry: entry ? Model.entryByName(service.monitors, entry.name) : null
  readonly property var caps: entry ? service.edidCaps[entry.name] : null
  property bool showPreview: false

  width: parent ? parent.width : 0
  spacing: Style.space(12)

  onEntryChanged: if (entry) service.loadEdid(entry.name)
  Component.onCompleted: if (entry) service.loadEdid(entry.name)

  // ------------------------------------------------------------- keyboard

  function arrangedOrder() {
    return service.draft.filter(Model.isArrangeable).slice().sort(function(a, b) { return (a.x - b.x) || (a.y - b.y) })
      .concat(service.draft.filter(function(e) { return !Model.isArrangeable(e) }))
  }

  function handleMove(dx, dy) {
    if (canvas.grabbed && entry) {
      service.nudge(entry.name, dx * 100, dy * 100)
      return true
    }
    if (dx !== 0) {
      var order = arrangedOrder()
      var i = 0
      for (var k = 0; k < order.length; k++) if (entry && order[k].name === entry.name) i = k
      var next = order[(i + dx + order.length) % order.length]
      if (next) service.select(next.name)
      return true
    }
    return false
  }

  function handleActivate() {
    if (entry && Model.isArrangeable(entry)) canvas.grabbed = !canvas.grabbed
  }

  function handleText(t) {
    if (canvas.grabbed && entry) {
      if (t === "H") { service.nudge(entry.name, -10, 0); return }
      if (t === "L") { service.nudge(entry.name, 10, 0); return }
      if (t === "K") { service.nudge(entry.name, 0, -10); return }
      if (t === "J") { service.nudge(entry.name, 0, 10); return }
    }
    if (t === "a") service.applyDraft()
    else if (t === "r") { canvas.grabbed = false; service.resetDraft() }
    else if (t === "p") showPreview = !showPreview
    else if (t === "f") { service.fullArrangeOpen = true; panel.close() }
    else if (entry && (t === "+" || t === "=" || t === "-")) stepScale(t === "-" ? -1 : 1)
    else if (entry && t === "o") service.setTransform(entry.name, ((entry.transform || 0) + 1) % 4 + ((entry.transform || 0) >= 4 ? 4 : 0))
    else if (entry && t === "e" && (entry.enabled === false || Model.enabledCount(service.draft) > 1))
      service.setEnabled(entry.name, entry.enabled === false)
  }

  function stepScale(direction) {
    var opts = Model.scaleOptions(entry)
    var at = -1
    for (var i = 0; i < opts.length; i++) if (Model.sameScale(opts[i].value, entry.scale)) at = i
    var next = opts[Math.max(0, Math.min(opts.length - 1, at + direction))]
    if (next) service.setScale(entry.name, next.value)
  }

  // --------------------------------------------------------------- canvas

  MonitorCanvas {
    id: canvas
    width: parent.width
    height: implicitHeight
    service: view.service
    notes: view.service.displayNotes
    foreground: view.fg
    fontFamily: view.ff
  }

  // Plugged in, but Hyprland does not show anything on it.
  Repeater {
    model: view.service.noSignal
    Text {
      required property string modelData
      width: view.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "⚠ " + modelData + " · No usable signal: plugged in, but nothing is shown on it. Try another cable or port, or Rescan."
      color: Color.urgent
      font.family: view.ff
      font.pixelSize: Style.font.caption
    }
  }

  // Displays that are off or mirroring have no place on the canvas.
  Flow {
    width: parent.width
    spacing: Style.space(6)
    visible: children.length > 1
    Repeater {
      model: view.service.draft.filter(function(e) { return !Model.isArrangeable(e) })
      Button {
        required property var modelData
        text: Model.displayLabel(modelData) + " · " + (modelData.enabled === false ? "off" : "mirrors " + modelData.mirror)
        fontSize: Style.font.caption
        foreground: view.fg
        fontFamily: view.ff
        bordered: true
        active: view.entry && view.entry.name === modelData.name
        onClicked: view.service.select(modelData.name)
      }
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    text: canvas.grabbed
      ? "Moving " + (view.entry ? view.entry.name : "") + ": h j k l by 100 px, H J K L by 10 px, Enter to put it down"
      : "Drag displays where they stand on your desk. h/l choose · Enter picks up · +/- scale · o rotate · e on/off · a apply · r reset"
    color: view.dim
    font.family: view.ff
    font.pixelSize: Style.font.caption
  }

  // ------------------------------------------------------------- inspector

  Section {
    visible: !!view.entry
    title: view.entry ? Model.displayLabel(view.entry).toUpperCase() : ""
    trailing: view.entry ? view.entry.name : ""
    foreground: view.fg
    fontFamily: view.ff

    FieldRow {
      label: "On"
      foreground: view.fg
      fontFamily: view.ff
      ToggleSwitch {
        anchors.right: parent.right
        checked: !!view.entry && view.entry.enabled !== false
        interactive: !!view.entry && (view.entry.enabled === false || Model.enabledCount(view.service.draft) > 1)
        foreground: view.fg
        onToggled: view.service.setEnabled(view.entry.name, view.entry.enabled === false)
      }
    }

    FieldRow {
      // The laptop panel mirrors through Omarchy's laptop modes (Display tab).
      visible: !!view.entry && view.entry.enabled !== false && view.service.draft.length > 1 && !view.entry.internal
      label: "Role"
      foreground: view.fg
      fontFamily: view.ff
      Dropdown {
        width: parent.width
        showLabel: false
        foreground: view.fg
        fontFamily: view.ff
        value: view.entry ? (view.entry.mirror || "") : ""
        options: {
          var list = [{ value: "", label: "Extend the desktop" }]
          var d = view.service.draft
          for (var i = 0; i < d.length; i++)
            if (view.entry && d[i].name !== view.entry.name && d[i].enabled !== false && !d[i].mirror)
              list.push({ value: d[i].name, label: "Mirror " + Model.displayLabel(d[i]) + " (" + d[i].name + ")" })
          return list
        }
        onChanged: function(v) { view.service.setMirror(view.entry.name, v) }
      }
    }

    FieldRow {
      visible: !!view.entry && view.entry.enabled !== false && view.entry.modes.length > 0
      label: "Resolution"
      hint: view.entry && view.service.fieldChanged(view.entry.name, ["width", "height", "refresh"])
            ? "Was " + view.service.baseValue(view.entry.name, "width") + "×" + view.service.baseValue(view.entry.name, "height") : ""
      foreground: view.fg
      fontFamily: view.ff
      Dropdown {
        width: parent.width
        showLabel: false
        foreground: view.fg
        fontFamily: view.ff
        value: view.entry ? view.entry.width + "x" + view.entry.height : ""
        options: view.entry ? Model.resolutionOptions(view.entry).map(function(o, i) {
          return { value: o.key, label: o.label + (i === 0 ? "  (native)" : "")
                   + (Model.isEdidOnly(view.entry, o.width, o.height) ? "  * from EDID" : "") }
        }) : []
        onChanged: function(v) {
          var p = v.split("x")
          view.service.setResolution(view.entry.name, Number(p[0]), Number(p[1]))
        }
      }
    }

    FieldRow {
      visible: !!view.entry && view.entry.enabled !== false && view.entry.modes.length > 0
      label: "Refresh rate"
      foreground: view.fg
      fontFamily: view.ff
      Dropdown {
        width: parent.width
        showLabel: false
        foreground: view.fg
        fontFamily: view.ff
        value: view.entry ? Model.formatRefresh(view.entry.refresh) : ""
        options: view.entry ? Model.refreshOptions(view.entry, view.entry.width, view.entry.height).map(function(r) {
          return { value: Model.formatRefresh(r), label: Model.formatRefresh(r) + " Hz"
                   + (Model.modelineFor(view.entry, view.entry.width, view.entry.height, r) ? "  * from EDID" : "") }
        }) : []
        onChanged: function(v) { view.service.setRefresh(view.entry.name, Number(v)) }
      }
    }

    // Let Hyprland choose: the preferred mode, the largest, or the fastest.
    FieldRow {
      visible: !!view.entry && view.entry.enabled !== false
      label: "Mode"
      hint: view.entry && view.entry.modeline ? "Applied as the EDID's own timing" : ""
      foreground: view.fg
      fontFamily: view.ff
      Dropdown {
        width: parent.width
        showLabel: false
        foreground: view.fg
        fontFamily: view.ff
        value: view.entry ? (view.entry.modeKeyword || "") : ""
        options: [{ value: "", label: "Exactly as chosen above" }, { value: "preferred", label: "The display's preferred mode" },
                  { value: "highres", label: "Highest resolution" }, { value: "highrr", label: "Highest refresh rate" }]
        onChanged: function(v) { view.service.setModeKeyword(view.entry.name, v) }
      }
    }

    FieldRow {
      visible: !!view.entry && view.entry.enabled !== false && !view.entry.mirror
      label: "Position"
      foreground: view.fg
      fontFamily: view.ff
      Dropdown {
        width: parent.width
        showLabel: false
        foreground: view.fg
        fontFamily: view.ff
        value: view.entry ? (view.entry.positionAuto || "") : ""
        options: [{ value: "", label: "Where it is on the canvas" }, { value: "auto", label: "Automatic" },
                  { value: "auto-right", label: "Automatic, to the right" }, { value: "auto-left", label: "Automatic, to the left" },
                  { value: "auto-up", label: "Automatic, above" }, { value: "auto-down", label: "Automatic, below" }]
        onChanged: function(v) { view.service.setPositionAuto(view.entry.name, v) }
      }
    }

    // A mode the display does not list: Hyprland tries it as a custom mode,
    // and the check after Apply reverts it if the display refuses.
    FieldRow {
      id: customRow
      visible: !!view.entry && view.entry.enabled !== false
      label: "Custom mode"
      hint: view.entry && view.entry.customMode ? "Not in the display's list" : "W×H@Hz, e.g. 2560x1080@75"
      foreground: view.fg
      fontFamily: view.ff
      Row {
        width: parent.width
        spacing: Style.space(6)
        TextField {
          id: customField
          width: parent.width - customSet.width - parent.spacing
          placeholderText: view.entry ? view.entry.width + "x" + view.entry.height + "@" + Model.formatRefresh(view.entry.refresh) : ""
          foreground: view.fg
          onActiveFocusChanged: view.panel.textEditing = activeFocus
          onAccepted: customSet.clicked()
          Keys.onEscapePressed: { text = ""; focus = false; view.panel.textEditing = false }
        }
        Button {
          id: customSet
          text: "Set"
          bordered: true
          fontSize: Style.font.caption
          foreground: view.fg
          fontFamily: view.ff
          onClicked: {
            var m = Model.parseMode(customField.text)
            if (!m) { view.service.say("error", "Type a mode like 2560x1080@75"); return }
            view.service.setCustomMode(view.entry.name, m.width, m.height, m.refresh)
            customField.text = ""
            customField.focus = false
            view.panel.textEditing = false
          }
        }
      }
    }

    FieldRow {
      visible: !!view.entry && view.entry.enabled !== false
      label: "Scale"
      hint: {
        var s = view.entry ? Model.suggestedScale(view.entry) : 0
        return s ? "Suggested " + Model.normalizeScale(s) + "x" : ""
      }
      foreground: view.fg
      fontFamily: view.ff
      Flow {
        width: parent.width
        spacing: Style.spacing.xs
        Repeater {
          model: view.entry ? Model.scaleOptions(view.entry) : []
          Button {
            required property var modelData
            text: modelData.label
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.sm
            foreground: view.fg
            fontFamily: view.ff
            bordered: true
            active: !!view.entry && Model.sameScale(view.entry.scale, modelData.value)
            onClicked: view.service.setScale(view.entry.name, modelData.value)
          }
        }
        // Every sharp scale for this mode, not only the presets.
        Dropdown {
          width: Style.space(96)
          showLabel: false
          foreground: view.fg
          fontFamily: view.ff
          value: ""
          options: [{ value: "", label: "More" }].concat(view.entry ? Model.sharpScales(view.entry.width, view.entry.height).map(function(v) {
            return { value: String(v), label: Model.normalizeScale(v) + "x" }
          }) : [])
          onChanged: function(v) { if (v) view.service.setScale(view.entry.name, Number(v)) }
        }
        PanelActionButton {
          visible: !!view.entry && view.service.fieldChanged(view.entry.name, ["scale"])
          iconText: "󰑓"
          tooltipText: "Back to " + Model.normalizeScale(view.service.baseValue(view.entry ? view.entry.name : "", "scale")) + "x"
          foreground: view.fg
          onClicked: view.service.resetFields(view.entry.name, ["scale"])
        }
      }
    }

    FieldRow {
      visible: !!view.entry && view.entry.enabled !== false && !view.entry.mirror
      label: "Rotation"
      foreground: view.fg
      fontFamily: view.ff
      // The angle and Flipped are separate choices (Hyprland's 0-7).
      Flow {
        width: parent.width
        spacing: Style.spacing.xs
        readonly property int t: view.entry ? (view.entry.transform || 0) : 0
        ButtonGroup {
          options: [{ value: "0", label: "Normal" }, { value: "1", label: "90°" }, { value: "2", label: "180°" }, { value: "3", label: "270°" }]
          value: String(parent.t % 4)
          foreground: view.fg
          fontFamily: view.ff
          fontSize: Style.font.caption
          focusable: false
          onChanged: function(v) { view.service.setTransform(view.entry.name, Number(v) + (parent.t >= 4 ? 4 : 0)) }
        }
        Button {
          text: "Flipped"
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.sm
          bordered: true
          active: parent.t >= 4
          foreground: view.fg
          fontFamily: view.ff
          onClicked: view.service.setTransform(view.entry.name, parent.t >= 4 ? parent.t - 4 : parent.t + 4)
        }
        PanelActionButton {
          visible: !!view.entry && view.service.fieldChanged(view.entry.name, ["transform"])
          iconText: "󰑓"
          tooltipText: "Back to " + Model.transformLabel(view.service.baseValue(view.entry ? view.entry.name : "", "transform"))
          foreground: view.fg
          onClicked: view.service.resetFields(view.entry.name, ["transform"])
        }
      }
    }

    FieldRow {
      visible: !!view.entry && view.entry.enabled !== false
      label: "Adaptive sync"
      hint: view.liveEntry && view.liveEntry.vrrActive ? "Active now" : ""
      foreground: view.fg
      fontFamily: view.ff
      Flow {
        width: parent.width
        spacing: Style.spacing.xs
        ButtonGroup {
          options: Model.VRR_MODES.map(function(m) { return { value: String(m.value), label: m.value === 3 ? "Games" : m.label } })
          value: view.entry ? String(view.entry.vrr) : "-1"
          foreground: view.fg
          fontFamily: view.ff
          fontSize: Style.font.caption
          focusable: false
          onChanged: function(v) { view.service.setVrr(view.entry.name, Number(v)) }
        }
        PanelActionButton {
          visible: !!view.entry && view.service.fieldChanged(view.entry.name, ["vrr"])
          iconText: "󰑓"
          tooltipText: "Back to the loaded value"
          foreground: view.fg
          onClicked: view.service.resetFields(view.entry.name, ["vrr"])
        }
      }
    }

    // Exact position in logical pixels; dragging and snapping stay the main way.
    FieldRow {
      visible: !!view.entry && Model.isArrangeable(view.entry)
      label: "Position X · Y"
      hint: view.entry && view.entry.positionAuto ? "Automatic (" + view.entry.positionAuto + ")" : "px"
      foreground: view.fg
      fontFamily: view.ff
      Row {
        width: parent.width
        spacing: Style.space(6)
        TextField {
          id: posX
          width: (parent.width - posReset.width - parent.spacing * 2) / 2
          text: view.entry ? String(view.entry.x) : ""
          foreground: view.fg
          inputMethodHints: Qt.ImhFormattedNumbersOnly
          onActiveFocusChanged: view.panel.textEditing = activeFocus
          onAccepted: { view.service.setPosition(view.entry.name, Number(text), Number(posY.text)); focus = false; view.panel.textEditing = false }
        }
        TextField {
          id: posY
          width: posX.width
          text: view.entry ? String(view.entry.y) : ""
          foreground: view.fg
          inputMethodHints: Qt.ImhFormattedNumbersOnly
          onActiveFocusChanged: view.panel.textEditing = activeFocus
          onAccepted: { view.service.setPosition(view.entry.name, Number(posX.text), Number(text)); focus = false; view.panel.textEditing = false }
        }
        PanelActionButton {
          id: posReset
          visible: !!view.entry && view.service.fieldChanged(view.entry.name, ["x", "y", "positionAuto"])
          iconText: "󰑓"
          tooltipText: "Back to where it is now"
          foreground: view.fg
          onClicked: view.service.resetFields(view.entry.name, ["x", "y", "positionAuto"])
        }
      }
    }

    // Placement relative to another display.
    FieldRow {
      id: placeRow
      visible: !!view.entry && Model.isArrangeable(view.entry) && view.service.draft.filter(Model.isArrangeable).length > 1
      label: "Place"
      foreground: view.fg
      fontFamily: view.ff
      property string anchorName: {
        var others = view.service.draft.filter(function(e) { return Model.isArrangeable(e) && (!view.entry || e.name !== view.entry.name) })
        return others.length ? others[0].name : ""
      }
      Column {
        width: parent.width
        spacing: Style.space(6)
        Dropdown {
          id: anchorPick
          width: parent.width
          showLabel: false
          foreground: view.fg
          fontFamily: view.ff
          value: placeRow.anchorName
          options: view.service.draft.filter(function(e) { return Model.isArrangeable(e) && (!view.entry || e.name !== view.entry.name) })
                     .map(function(e) { return { value: e.name, label: "Next to " + Model.displayLabel(e) + " (" + e.name + ")" } })
          onChanged: function(v) { placeRow.anchorName = v }
        }
        Row {
          spacing: Style.spacing.xs
          Repeater {
            model: [{ side: "left", label: "Left" }, { side: "right", label: "Right" }, { side: "above", label: "Above" }, { side: "below", label: "Below" }]
            Button {
              required property var modelData
              text: modelData.label
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.sm
              foreground: view.fg
              fontFamily: view.ff
              bordered: true
              active: !!view.entry && Layout.sideOf(view.service.draft.filter(Model.isArrangeable), view.entry.name, placeRow.anchorName) === modelData.side
              onClicked: view.service.place(view.entry.name, placeRow.anchorName, modelData.side, "start")
            }
          }
        }
        ButtonGroup {
          options: [{ value: "start", label: "Align start" }, { value: "center", label: "Centre" }, { value: "end", label: "End" }]
          value: ""
          foreground: view.fg
          fontFamily: view.ff
          fontSize: Style.font.caption
          focusable: false
          onChanged: function(v) { view.service.alignSelected(v) }
        }
      }
    }
  }

  // --------------------------------------------------------- layout health

  Section {
    visible: view.service.layoutIssues.length > 0
    title: "LAYOUT"
    trailing: view.service.layoutIssues.length + " ISSUE" + (view.service.layoutIssues.length === 1 ? "" : "S")
    foreground: view.fg
    fontFamily: view.ff

    Repeater {
      model: view.service.layoutIssues
      Text {
        required property var modelData
        width: view.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: "⚠ " + modelData.message
        color: Color.urgent
        font.family: view.ff
        font.pixelSize: Style.font.caption
      }
    }
    Button {
      anchors.right: parent.right
      text: "Repair"
      tooltipText: "Re-seat the displays flush, starting at 0×0, and fix broken mirrors (with the countdown)"
      bordered: true
      fontSize: Style.font.caption
      foreground: view.fg
      fontFamily: view.ff
      onClicked: view.service.repairLayout()
    }
  }

  // -------------------------------------------------------------- insights

  Section {
    id: insightSection
    readonly property var insights: view.liveEntry ? Model.healthInsights(view.liveEntry, view.caps && !view.caps.missing ? view.caps : null) : []
    visible: insights.length > 0
    title: "INSIGHTS"
    foreground: view.fg
    fontFamily: view.ff

    Repeater {
      model: insightSection.insights
      FieldRow {
        required property var modelData
        label: modelData.message
        labelRatio: 0.66
        foreground: modelData.level === "warning" ? Color.urgent : view.fg
        fontFamily: view.ff
        Button {
          visible: !!modelData.fix
          anchors.right: parent.right
          text: modelData.fixLabel
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.sm
          foreground: view.fg
          fontFamily: view.ff
          bordered: true
          onClicked: view.service.applyFix(view.entry.name, modelData.fix)
        }
        Text {
          visible: !modelData.fix
          anchors.right: parent.right
          width: parent.width
          horizontalAlignment: Text.AlignRight
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: modelData.fixLabel
          color: view.dim
          font.family: view.ff
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // --------------------------------------------------------------- details

  Section {
    visible: !!view.liveEntry
    title: "HARDWARE"
    trailing: "CLICK A VALUE TO COPY"
    foreground: view.fg
    fontFamily: view.ff

    Grid {
      id: hwGrid
      width: parent.width
      columns: 4
      columnSpacing: Style.space(8)
      rowSpacing: Style.space(4)
      readonly property real keyWidth: Style.space(78)
      readonly property real valueWidth: (width - 2 * keyWidth - 3 * columnSpacing) / 2

      Repeater {
        model: {
          var e = view.liveEntry
          if (!e) return []
          var native = Model.nativeMode(e)
          var rows = [
            ["Connector", e.name], ["Model", e.model], ["Type", e.internal ? "Built-in display" : "External display"],
            ["Make", e.make], ["Max resolution", native ? native.width + "×" + native.height : ""], ["Serial", e.serial],
            ["Panel size", e.physicalWidth ? (Model.inchesLabel(e) + " (" + e.physicalWidth + "×" + e.physicalHeight + " mm)") : ""],
            ["Density", Model.pixelDensity(e) ? Model.pixelDensity(e) + " PPI" : ""],
            ["Mode", Model.modeLabel(e)], ["Format", e.format + " (" + e.liveBitdepth + "-bit)"],
            ["Colour", e.cm], ["Position", e.x + " × " + e.y]
          ]
          var lines = Model.capabilityLines(view.caps && !view.caps.missing ? view.caps : null)
          for (var i = 0; i < lines.length; i++) rows.push([lines[i].label, lines[i].value])
          var flat = []
          for (var k = 0; k < rows.length; k++) {
            if (!rows[k][1]) continue
            flat.push({ text: rows[k][0], key: true })
            flat.push({ text: String(rows[k][1]), key: false })
          }
          return flat
        }
        Text {
          required property var modelData
          width: modelData.key ? hwGrid.keyWidth : hwGrid.valueWidth
          textFormat: Text.PlainText
          text: modelData.text
          color: modelData.key ? view.dim : view.fg
          font.family: view.ff
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          MouseArea {
            anchors.fill: parent
            enabled: !parent.modelData.key
            cursorShape: Qt.PointingHandCursor
            onClicked: view.service.run(["wl-copy"], parent.modelData.text)
          }
        }
      }
    }

    Button {
      anchors.right: parent.right
      text: "Identify"
      tooltipText: "Show this display's number on it"
      fontSize: Style.font.caption
      bordered: true
      foreground: view.fg
      fontFamily: view.ff
      onClicked: view.service.identifyOne(view.liveEntry.name)
    }
  }

  // --------------------------------------------------------------- actions

  PanelSeparator { foreground: view.fg }

  Row {
    anchors.right: parent.right
    spacing: Style.space(8)

    Button {
      text: "Rescan"
      tooltipText: "Read displays, EDIDs and DDC again"
      bordered: true
      foreground: view.fg
      fontFamily: view.ff
      onClicked: view.service.rescan()
    }
    Button {
      text: "Full screen"
      tooltipText: "Arrange on a whole screen (f)"
      bordered: true
      foreground: view.fg
      fontFamily: view.ff
      onClicked: { view.service.fullArrangeOpen = true; view.panel.close() }
    }
    Button {
      text: "Reset"
      bordered: true
      foreground: view.fg
      fontFamily: view.ff
      onClicked: { canvas.grabbed = false; view.service.resetDraft() }
    }
    Button {
      text: view.showPreview ? "Hide plan" : "Preview"
      bordered: true
      foreground: view.fg
      fontFamily: view.ff
      onClicked: view.showPreview = !view.showPreview
    }
    Button {
      text: "Apply"
      bordered: true
      active: view.service.dirty
      foreground: view.fg
      fontFamily: view.ff
      onClicked: { canvas.grabbed = false; view.service.applyDraft() }
    }
  }

  Text {
    visible: !!view.service.draftPlan && view.service.draftPlan.warnings.length > 0
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    text: view.service.draftPlan ? view.service.draftPlan.warnings.map(function(w) { return "⚠ " + w.message }).join("\n") : ""
    color: Color.urgent
    font.family: view.ff
    font.pixelSize: Style.font.caption
  }

  Rectangle {
    visible: view.showPreview
    width: parent.width
    height: previewText.implicitHeight + Style.space(16)
    radius: Style.cornerRadius
    color: Util.alpha(view.fg, 0.05)
    Text {
      id: previewText
      x: Style.space(8)
      y: Style.space(8)
      width: parent.width - Style.space(16)
      wrapMode: Text.WrapAnywhere
      textFormat: Text.PlainText
      text: view.showPreview ? view.service.previewText() : ""
      color: view.fg
      font.family: "monospace"
      font.pixelSize: Style.font.caption
    }
  }
}
