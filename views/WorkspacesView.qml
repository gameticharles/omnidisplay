import QtQuick
import qs.Ui
import qs.Commons
import "../lib/Model.js" as Model
import "../lib/Profiles.js" as Profiles
import "../components"

// The Spaces tab: which workspaces live on which display, with the plan drawn
// on the stage as chips that glide to their new display as the plan changes.
// Sequential gives each display a run (1-3, 4-6, ...), interleaved deals them
// out in turn, manual pins each one; the monitor order says which display
// comes first. Saved with the profile for this set of displays; Off leaves
// workspaces to Hyprland or to another tool such as hyprsplit.
Column {
  id: view

  required property var panel
  readonly property var service: panel.service
  readonly property color fg: panel.foreground
  readonly property string ff: panel.fontFamily
  readonly property color dim: panel.dim

  readonly property var plan: Profiles.cleanWorkspaces(service.draftWorkspaces)
  readonly property var ordered: Profiles.workspaceOrder(service.draft, plan)
  readonly property var rules: Profiles.planWorkspaces(service.draft, plan)
  readonly property var ids: Model.identityKeys(service.draft)

  width: parent ? parent.width : 0
  spacing: Style.space(12)

  function update(field, value) {
    var next = JSON.parse(JSON.stringify(plan))
    next[field] = value
    service.setWorkspacePlan(next)
  }

  function handleText(t) {
    if (t === "a") service.applyDraft()
    else if (t === "r") service.resetDraft()
  }

  // A workspace's display, moved one place along the monitor order.
  function shiftWorkspace(ws, delta) {
    var r = rules[ws - 1]
    if (!r || !ordered.length) return
    var i = 0
    for (var k = 0; k < ordered.length; k++) if (ordered[k].name === r.name) i = k
    var target = ordered[(i + delta + ordered.length) % ordered.length]
    var manual = JSON.parse(JSON.stringify(plan.manual))
    // Switching to manual keeps every other workspace where it is now.
    if (plan.strategy !== "manual") for (var w = 0; w < rules.length; w++) manual[String(rules[w].workspace)] = ids[rules[w].name]
    manual[String(ws)] = ids[target.name]
    var next = JSON.parse(JSON.stringify(plan))
    next.manual = manual
    next.strategy = "manual"
    service.setWorkspacePlan(next)
  }

  MonitorCanvas {
    width: parent.width
    height: Style.space(190)
    service: view.service
    interactive: false
    workspacePlan: view.rules
    foreground: view.fg
    fontFamily: view.ff
  }

  Section {
    separator: false
    title: "WORKSPACE PLANNER"
    trailing: service.activeProfile ? "SAVED WITH " + service.activeProfile.name.toUpperCase() : "SAVED WITH THE NEW PROFILE"
    foreground: view.fg
    fontFamily: view.ff

    ButtonGroup {
      width: parent.width
      options: [
        { value: "off", label: "Off" }, { value: "sequential", label: "Sequential" },
        { value: "interleaved", label: "Interleaved" }, { value: "manual", label: "Manual" }
      ]
      value: view.plan.strategy
      foreground: view.fg
      fontFamily: view.ff
      fontSize: Style.font.caption
      focusable: false
      onChanged: function(v) { view.update("strategy", v) }
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: {
        switch (view.plan.strategy) {
        case "sequential": return "Each display gets a run of workspaces, in the monitor order below."
        case "interleaved": return "Workspaces are dealt out in turn: 1 to the first display, 2 to the next…"
        case "manual": return "Move each workspace with its arrows, or pick its display."
        default: return "OmniDisplay writes no workspace rules. Hyprland, or a tool such as hyprsplit, decides; the plan is kept for later."
        }
      }
      color: view.dim
      font.family: view.ff
      font.pixelSize: Style.font.caption
    }

    // Steppers: − value +, and the value can be typed.
    Row {
      visible: view.plan.strategy !== "off"
      width: parent.width
      spacing: Style.space(10)

      Repeater {
        model: view.plan.strategy === "sequential"
          ? [{ key: "count", label: "WORKSPACES", min: 1 }, { key: "groupSize", label: "GROUP SIZE", min: 0 }]
          : [{ key: "count", label: "WORKSPACES", min: 1 }]
        Column {
          id: stepper
          required property var modelData
          width: view.plan.strategy === "sequential" ? (view.width - Style.space(10)) / 2 : view.width
          spacing: Style.space(4)
          Text {
            textFormat: Text.PlainText
            text: stepper.modelData.label + (stepper.modelData.key === "groupSize" && view.plan.groupSize === 0 ? "  (even split)" : "")
            color: view.dim
            font.family: view.ff
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          BorderSurface {
            width: parent.width
            height: Style.spacing.controlHeight
            radius: Style.cornerRadius
            color: Util.alpha(view.fg, 0.04)
            borderSpec: Border.flat(Util.alpha(view.fg, 0.25), 1)
            PanelActionButton {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰍴"
              foreground: view.fg
              onClicked: view.update(stepper.modelData.key, Math.max(stepper.modelData.min, view.plan[stepper.modelData.key] - 1))
            }
            TextInput {
              anchors.centerIn: parent
              width: Style.space(60)
              horizontalAlignment: TextInput.AlignHCenter
              text: String(view.plan[stepper.modelData.key])
              color: view.fg
              font.family: view.ff
              font.pixelSize: Style.font.body
              validator: IntValidator { bottom: stepper.modelData.min; top: 99 }
              onActiveFocusChanged: view.panel.textEditing = activeFocus
              onAccepted: { view.update(stepper.modelData.key, Number(text)); focus = false; view.panel.textEditing = false }
            }
            PanelActionButton {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰐕"
              foreground: view.fg
              onClicked: view.update(stepper.modelData.key, Math.min(99, view.plan[stepper.modelData.key] + 1))
            }
          }
        }
      }
    }

    FieldRow {
      visible: view.plan.strategy !== "off"
      label: "Persistence"
      hint: "Persistent workspaces stay with nothing open"
      labelRatio: 0.3
      foreground: view.fg
      fontFamily: view.ff
      ButtonGroup {
        anchors.right: parent.right
        options: [{ value: "none", label: "None" }, { value: "first", label: "First per display" }, { value: "all", label: "All" }]
        value: view.plan.persistence
        foreground: view.fg
        fontFamily: view.ff
        fontSize: Style.font.caption
        focusable: false
        onChanged: function(v) { view.update("persistence", v) }
      }
    }
  }

  Section {
    visible: view.plan.strategy !== "off" && view.ordered.length > 1
    title: "MONITOR ORDER"
    trailing: "WHO GETS 1 FIRST"
    foreground: view.fg
    fontFamily: view.ff

    Repeater {
      model: view.ordered
      CursorSurface {
        id: orderRow
        required property var modelData
        required property int index
        width: view.width
        implicitHeight: Style.spacing.controlHeight + Style.space(10)
        foreground: view.fg
        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: (orderRow.index + 1) + ".  " + Model.displayLabel(orderRow.modelData) + "  ·  " + orderRow.modelData.name
          color: view.fg
          font.family: view.ff
          font.pixelSize: Style.font.body
        }
        Row {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)
          PanelActionButton {
            iconText: "󰁍"
            tooltipText: "Earlier"
            foreground: orderRow.index > 0 ? view.fg : view.dim
            onClicked: if (orderRow.index > 0) view.service.setWorkspacePlan(Profiles.moveInOrder(view.service.draft, view.plan, orderRow.modelData.name, -1))
          }
          PanelActionButton {
            iconText: "󰁔"
            tooltipText: "Later"
            foreground: orderRow.index < view.ordered.length - 1 ? view.fg : view.dim
            onClicked: if (orderRow.index < view.ordered.length - 1) view.service.setWorkspacePlan(Profiles.moveInOrder(view.service.draft, view.plan, orderRow.modelData.name, 1))
          }
        }
      }
    }
  }

  Section {
    visible: view.plan.strategy !== "off" && view.ordered.length > 0
    title: view.plan.strategy === "manual" ? "WORKSPACES" : "WORKSPACE PLAN"
    trailing: view.plan.strategy === "manual" ? "" : "← → ON A WORKSPACE PINS IT (MANUAL)"
    foreground: view.fg
    fontFamily: view.ff

    // Summary: each display and its workspaces.
    Repeater {
      model: view.plan.strategy === "manual" ? [] : view.ordered
      FieldRow {
        required property var modelData
        label: Model.displayLabel(modelData) + "  ·  " + modelData.name
        labelRatio: 0.6
        foreground: view.fg
        fontFamily: view.ff
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: view.rules.filter(function(r) { return r.name === modelData.name }).map(function(r) { return r.workspace + (r.persistent ? "•" : "") }).join(", ")
          color: Color.accent
          font.family: view.ff
          font.pixelSize: Style.font.body
          font.bold: true
          wrapMode: Text.WordWrap
        }
      }
    }

    // Manual: each workspace with its display and arrows.
    Repeater {
      model: view.plan.strategy === "manual" ? view.rules : []
      CursorSurface {
        id: wsRow
        required property var modelData
        width: view.width
        implicitHeight: Style.spacing.controlHeight + Style.space(6)
        foreground: view.fg
        Rectangle {
          id: chip
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(26)
          height: Style.space(22)
          radius: Style.cornerRadius
          color: Util.alpha(Color.accent, 0.8)
          Text {
            anchors.centerIn: parent
            text: String(wsRow.modelData.workspace)
            color: Color.background
            font.family: view.ff
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
        Text {
          anchors.left: chip.right
          anchors.leftMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: Model.displayLabel(Model.entryByName(view.service.draft, wsRow.modelData.name)) + "  ·  " + wsRow.modelData.name
                + (wsRow.modelData.persistent ? "  · persistent" : "")
          color: view.fg
          font.family: view.ff
          font.pixelSize: Style.font.body
        }
        Row {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)
          PanelActionButton {
            iconText: "󰁍"
            tooltipText: "To the previous display"
            foreground: view.fg
            onClicked: view.shiftWorkspace(wsRow.modelData.workspace, -1)
          }
          PanelActionButton {
            iconText: "󰁔"
            tooltipText: "To the next display"
            foreground: view.fg
            onClicked: view.shiftWorkspace(wsRow.modelData.workspace, 1)
          }
        }
      }
    }
  }

  PanelSeparator { foreground: view.fg }

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
