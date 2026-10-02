import QtQuick
import qs.Ui
import qs.Commons
import "../lib/Model.js" as Model
import "../lib/Profiles.js" as Profiles
import "../components"

// The Spaces tab: which workspaces live on which display. Sequential gives
// each display a run (1-3, 4-6, ...), interleaved deals them out in turn
// (odd/even on two displays), manual pins each one. Saved with the profile
// for this set of displays and applied with it; Off leaves workspaces to
// Hyprland or to another tool such as hyprsplit.
Column {
  id: view

  required property var panel
  readonly property var service: panel.service
  readonly property color fg: panel.foreground
  readonly property string ff: panel.fontFamily
  readonly property color dim: panel.dim

  readonly property var plan: Profiles.cleanWorkspaces(service.draftWorkspaces)
  readonly property var arranged: Profiles.workspaceOrder(service.draft)
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

  Section {
    separator: false
    title: "WORKSPACES"
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
        case "sequential": return "Each display gets a run of workspaces, left to right."
        case "interleaved": return "Workspaces are dealt out in turn: 1 left, 2 right, 3 left…"
        case "manual": return "Pick a display for each workspace."
        default: return "OmniDisplay writes no workspace rules. Hyprland, or a tool such as hyprsplit, decides."
        }
      }
      color: view.dim
      font.family: view.ff
      font.pixelSize: Style.font.caption
    }

    FieldRow {
      visible: view.plan.strategy !== "off"
      label: "Workspaces"
      foreground: view.fg
      fontFamily: view.ff
      NumberField {
        anchors.right: parent.right
        from: 1
        to: 99
        value: view.plan.count
        foreground: view.fg
        fontFamily: view.ff
        onModified: function(v) { view.update("count", v) }
      }
    }

    FieldRow {
      visible: view.plan.strategy === "sequential"
      label: "Per display"
      hint: "0 splits them evenly"
      foreground: view.fg
      fontFamily: view.ff
      NumberField {
        anchors.right: parent.right
        from: 0
        to: 99
        value: view.plan.groupSize
        foreground: view.fg
        fontFamily: view.ff
        onModified: function(v) { view.update("groupSize", v) }
      }
    }

    Toggle {
      visible: view.plan.strategy !== "off"
      width: parent.width
      label: "Keep them even when empty"
      description: "Persistent workspaces stay on their display with nothing open."
      checked: view.plan.persistent
      foreground: view.fg
      fontFamily: view.ff
      onClicked: view.update("persistent", !view.plan.persistent)
    }
  }

  Section {
    visible: view.plan.strategy !== "off" && view.arranged.length > 0
    title: "RESULT"
    foreground: view.fg
    fontFamily: view.ff

    Repeater {
      model: view.arranged
      FieldRow {
        id: resultRow
        required property var modelData
        readonly property var mine: view.rules.filter(function(r) { return r.name === modelData.name }).map(function(r) { return r.workspace })
        label: Model.displayLabel(modelData)
        hint: modelData.name
        foreground: view.fg
        fontFamily: view.ff
        Flow {
          width: parent.width
          spacing: Style.space(3)
          layoutDirection: Qt.RightToLeft
          Repeater {
            model: resultRow.mine
            Rectangle {
              required property var modelData
              width: Style.space(22)
              height: Style.space(20)
              radius: Style.cornerRadius
              color: Util.alpha(Color.accent, 0.25)
              Text {
                anchors.centerIn: parent
                text: String(parent.modelData)
                color: view.fg
                font.family: view.ff
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }
        }
      }
    }
  }

  Section {
    visible: view.plan.strategy === "manual"
    title: "PIN EACH WORKSPACE"
    foreground: view.fg
    fontFamily: view.ff

    Repeater {
      model: view.plan.strategy === "manual" ? view.plan.count : 0
      FieldRow {
        id: pinRow
        required property int index
        readonly property int ws: index + 1
        label: "Workspace " + ws
        foreground: view.fg
        fontFamily: view.ff
        Dropdown {
          width: parent.width
          showLabel: false
          foreground: view.fg
          fontFamily: view.ff
          value: {
            var r = view.rules[pinRow.index]
            return r ? view.ids[r.name] || "" : ""
          }
          options: view.arranged.map(function(e) { return { value: view.ids[e.name], label: Model.displayLabel(e) + " (" + e.name + ")" } })
          onChanged: function(v) {
            var manual = JSON.parse(JSON.stringify(view.plan.manual))
            manual[String(pinRow.ws)] = v
            view.update("manual", manual)
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
