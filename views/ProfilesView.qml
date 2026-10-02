import QtQuick
import qs.Ui
import qs.Commons
import "../lib/Model.js" as Model
import "../lib/Profiles.js" as Profiles
import "../components"

// The Profiles tab: one saved arrangement per set of displays, switched to
// automatically when that set is connected; the monitors.lua backups with
// restore; cleanup of what other display plugins left behind; the report.
Column {
  id: view

  required property var panel
  readonly property var service: panel.service
  readonly property color fg: panel.foreground
  readonly property string ff: panel.fontFamily
  readonly property color dim: panel.dim

  property string renaming: ""
  property string confirmDelete: ""
  property string confirmRestore: ""
  readonly property var connectedKey: Profiles.connectedKey(service.monitors)

  width: parent ? parent.width : 0
  spacing: Style.space(12)

  Component.onCompleted: service.loadBackups()

  function displaysText(p) {
    return p.displays.map(function(id) { return id.length > 28 ? id.substring(0, 26) + "…" : id }).join(" + ")
  }

  function stampText(stamp) {
    var d = new Date(Number(stamp) * 1000)
    return d.toLocaleString(Qt.locale(), "ddd d MMM yyyy  HH:mm:ss")
  }

  // ------------------------------------------------------------- current

  Section {
    separator: false
    title: "CONNECTED NOW"
    trailing: view.service.autoProfiles ? "SWITCHES AUTOMATICALLY" : "AUTO SWITCH OFF"
    foreground: view.fg
    fontFamily: view.ff

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: view.service.activeProfile
        ? "\"" + view.service.activeProfile.name + "\" is the profile for these displays. Keeping a change updates it."
        : "These displays have no profile yet. Keep a change, or save the current layout as one."
      color: view.fg
      font.family: view.ff
      font.pixelSize: Style.font.body
    }

    Row {
      visible: !view.service.activeProfile && !!view.service.nearestProfile
      width: parent.width
      spacing: Style.space(8)
      Text {
        width: parent.width - nearBtn.width - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: view.service.nearestProfile ? "\"" + view.service.nearestProfile.name + "\" shares displays with these. Start from its settings?" : ""
        color: view.dim
        font.family: view.ff
        font.pixelSize: Style.font.caption
      }
      Button {
        id: nearBtn
        text: "Start from it"
        bordered: true
        fontSize: Style.font.caption
        foreground: view.fg
        fontFamily: view.ff
        onClicked: view.service.startFromNearest()
      }
    }

    Row {
      visible: !view.service.activeProfile
      width: parent.width
      spacing: Style.space(8)
      TextField {
        id: newName
        width: parent.width - saveBtn.width - parent.spacing
        placeholderText: Profiles.suggestName(view.service.monitors)
        foreground: view.fg
        onActiveFocusChanged: view.panel.textEditing = activeFocus
        onAccepted: { view.service.saveCurrentAsProfile(text); text = ""; focus = false }
      }
      Button {
        id: saveBtn
        text: "Save"
        bordered: true
        foreground: view.fg
        fontFamily: view.ff
        onClicked: { view.service.saveCurrentAsProfile(newName.text); newName.text = ""; newName.focus = false }
      }
    }
  }

  // ------------------------------------------------------------ profiles

  Section {
    title: "PROFILES"
    trailing: view.service.store.profiles.length ? String(view.service.store.profiles.length) : ""
    foreground: view.fg
    fontFamily: view.ff

    Text {
      visible: view.service.store.profiles.length === 0
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "None yet. Every set of displays you keep a change on gets one: the desk, the office, the projector."
      color: view.dim
      font.family: view.ff
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: view.service.store.profiles

      CursorSurface {
        id: card
        required property var modelData
        readonly property bool here: Profiles.sameSet(modelData.displays, view.connectedKey)
        width: view.width
        implicitHeight: cardCol.implicitHeight + Style.space(14)
        current: here
        foreground: view.fg
        fill: Style.hoverFillFor(view.fg, Color.accent)
        currentFill: Style.selectedFillFor(view.fg, Color.accent)

        Column {
          id: cardCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          spacing: Style.space(4)

          Item {
            width: parent.width
            implicitHeight: Math.max(nameText.implicitHeight, actions.implicitHeight)

            Text {
              id: nameText
              visible: view.renaming !== card.modelData.id
              anchors.left: parent.left
              anchors.right: actions.left
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: card.modelData.name + (card.here ? "  · connected" : "")
              color: view.fg
              font.family: view.ff
              font.pixelSize: Style.font.body
              font.bold: card.here
              elide: Text.ElideRight
            }
            TextField {
              visible: view.renaming === card.modelData.id
              anchors.left: parent.left
              anchors.right: actions.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: card.modelData.name
              foreground: view.fg
              onVisibleChanged: if (visible) { forceActiveFocus(); selectAll() }
              onActiveFocusChanged: view.panel.textEditing = activeFocus
              onAccepted: { view.service.renameProfile(card.modelData.id, text); view.renaming = ""; view.panel.textEditing = false }
              Keys.onEscapePressed: { view.renaming = ""; view.panel.textEditing = false }
            }

            Row {
              id: actions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              PanelActionButton {
                visible: card.here
                iconText: "󰐊"
                tooltipText: "Apply this profile"
                foreground: view.fg
                onClicked: view.service.applyProfile(card.modelData.id)
              }
              PanelActionButton {
                iconText: "󰏫"
                tooltipText: "Rename"
                foreground: view.fg
                onClicked: view.renaming = view.renaming === card.modelData.id ? "" : card.modelData.id
              }
              PanelActionButton {
                iconText: view.confirmDelete === card.modelData.id ? "󰄬" : "󰆴"
                tooltipText: view.confirmDelete === card.modelData.id ? "Click again to delete" : "Delete"
                foreground: view.confirmDelete === card.modelData.id ? Color.urgent : view.fg
                onClicked: {
                  if (view.confirmDelete === card.modelData.id) { view.service.deleteProfile(card.modelData.id); view.confirmDelete = "" }
                  else view.confirmDelete = card.modelData.id
                }
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: view.displaysText(card.modelData)
            color: view.dim
            font.family: view.ff
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Row {
            spacing: Style.space(6)
            visible: card.modelData.displays.length > 1
            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "Laptop:"
              color: view.dim
              font.family: view.ff
              font.pixelSize: Style.font.caption
            }
            ButtonGroup {
              options: Profiles.LAPTOP_MODES.map(function(m) { return { value: m, label: Profiles.laptopModeLabel(m) } })
              value: card.modelData.laptop
              foreground: view.fg
              fontFamily: view.ff
              fontSize: Style.font.caption
              focusable: false
              onChanged: function(v) { view.service.setProfileLaptop(card.modelData.id, v) }
            }
          }

          Text {
            visible: card.modelData.workspaces.strategy !== "off"
            textFormat: Text.PlainText
            text: "Workspaces: " + card.modelData.workspaces.strategy + ", " + card.modelData.workspaces.count
            color: view.dim
            font.family: view.ff
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // ----------------------------------------------------- monitors.lua tidy

  Section {
    visible: view.service.foreignRules.length > 0
    title: "LEFT BEHIND IN MONITORS.LUA"
    trailing: String(view.service.foreignRules.length)
    foreground: view.fg
    fontFamily: view.ff

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Other display plugins left these. Folding them in writes the current layout as OmniDisplay's block and removes them, after a backup."
      color: view.dim
      font.family: view.ff
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: view.service.foreignRules
      Text {
        required property var modelData
        width: view.width
        textFormat: Text.PlainText
        text: "• " + modelData.label + (modelData.kind === "rule" ? ": " + modelData.text.trim() : "")
        color: view.fg
        font.family: "monospace"
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Button {
      anchors.right: parent.right
      text: "Fold into OmniDisplay"
      bordered: true
      foreground: view.fg
      fontFamily: view.ff
      onClicked: view.service.cleanupForeign(view.service.foreignRules)
    }
  }

  // --------------------------------------------------------------- backups

  Section {
    title: "MONITORS.LUA BACKUPS"
    trailing: view.service.persistMode === "service-only" ? "NOT WRITTEN (SERVICE ONLY)" : (view.service.blockPresent ? "BLOCK PRESENT" : "NO BLOCK YET")
    foreground: view.fg
    fontFamily: view.ff

    Text {
      visible: view.service.backups.length === 0
      width: parent.width
      textFormat: Text.PlainText
      text: "None yet. One is taken before every save."
      color: view.dim
      font.family: view.ff
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: view.service.backups
      FieldRow {
        required property var modelData
        label: view.stampText(modelData.stamp)
        hint: modelData.size + " bytes"
        labelRatio: 0.7
        foreground: view.fg
        fontFamily: view.ff
        Button {
          anchors.right: parent.right
          text: view.confirmRestore === modelData.stamp ? "Confirm" : "Restore"
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.sm
          bordered: true
          active: view.confirmRestore === modelData.stamp
          foreground: view.fg
          fontFamily: view.ff
          onClicked: {
            if (view.confirmRestore === modelData.stamp) { view.service.restoreBackup(modelData.stamp); view.confirmRestore = "" }
            else view.confirmRestore = modelData.stamp
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- help

  Section {
    title: "TROUBLE"
    foreground: view.fg
    fontFamily: view.ff

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "If a change leaves you without a usable screen, wait: it reverts on its own. To undo the last kept change from a terminal or a key binding: omarchy-shell omnidisplay emergency"
      color: view.dim
      font.family: view.ff
      font.pixelSize: Style.font.caption
    }

    Button {
      anchors.right: parent.right
      text: "Copy diagnostic report"
      bordered: true
      foreground: view.fg
      fontFamily: view.ff
      onClicked: view.service.copyReport()
    }
  }
}
