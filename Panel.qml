import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Ui
import qs.Commons
import "lib/Model.js" as Model
import "lib/Profiles.js" as Profiles
import "lib/Cast.js" as Cast
import "components"
import "views"

// The OmniDisplay bar widget. Omarchy builds one per monitor, so this file
// only renders: state, the draft and every action live in Service.qml, which
// exists once. Replaces the built-in Display widget (manifest clonedFrom),
// so it also answers SUPER + CTRL + D.
Panel {
  id: root
  manageIpc: false

  // ------------------------------------------------------------- service

  property var service: null

  function bindService() {
    if (service) return
    var host = bar && bar.shell ? bar.shell : null
    if (!host || typeof host.serviceFor !== "function") return
    var s = host.serviceFor("omnidisplay")
    if (!s) return
    service = s
    service.applySettings(settings)
  }

  onBarChanged: bindService()
  onSettingsChanged: if (service) service.applySettings(settings)
  Component.onCompleted: bindService()

  // The service can load after the first bar; try again shortly.
  Timer {
    interval: 500
    repeat: true
    running: !root.service
    onTriggered: root.bindService()
  }

  readonly property bool ready: !!service
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.4)

  // ------------------------------------------------------------------ tabs

  property string tab: "basics"
  readonly property var tabs: {
    var list = [
      { value: "basics", label: "Display", icon: "󰃟" },
      { value: "arrange", label: "Arrange", icon: "󰍺" }
    ]
    if (setting("showColor", true) !== false) list.push({ value: "color", label: "Colour", icon: "󰏘" })
    list.push({ value: "workspaces", label: "Spaces", icon: "󱂬" })
    list.push({ value: "profiles", label: "Profiles", icon: "󰆓" })
    if (setting("showCast", true) !== false) list.push({ value: "cast", label: "Cast", icon: "󰄘" })
    return list
  }

  function selectTab(value) {
    for (var i = 0; i < tabs.length; i++) if (tabs[i].value === value) { tab = value; return }
  }

  onTabChanged: if (service) service.castViewOpen = opened && tab === "cast"

  Connections {
    target: root.service
    function onTabRequestChanged() { root.selectTab(root.service.requestedTab) }
  }

  onOpenedChanged: {
    if (!service) return
    if (opened) {
      service.panelOpened()
      service.castViewOpen = tab === "cast"
    } else {
      service.panelClosed()
    }
  }

  // Inline editors (rename, PIN entry) take the keyboard from the catcher.
  property bool textEditing: false

  // ---------------------------------------------------------------- bar

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property string labelMode: vertical ? "none" : String(setting("barLabel", "none"))
  readonly property string glyph: {
    if (!service) return "󰍹"
    if (service.phase === "confirm") return "󱎫"
    if (Cast.hasConnected(service.castState)) return "󰄙"
    if (service.vncState.running) return "󰓶"
    return service.enabledCount > 1 ? "󰍺" : "󰍹"
  }
  readonly property string barLabel: {
    if (!service) return ""
    if (labelMode === "count") return String(service.enabledCount)
    if (labelMode === "profile") return service.activeProfile ? service.activeProfile.name : ""
    if (labelMode === "cast") return Cast.hasConnected(service.castState) ? Cast.statusText(service.castState) : ""
    return ""
  }
  readonly property string tooltip: {
    if (!service) return "Displays"
    var parts = [service.enabledCount + " display" + (service.enabledCount === 1 ? "" : "s")]
    if (service.activeProfile) parts.push(service.activeProfile.name)
    if (service.laptopMode) parts.push(Profiles.laptopModeLabel(service.laptopMode))
    if (Cast.hasConnected(service.castState)) parts.push(Cast.statusText(service.castState))
    return parts.join(" · ")
  }

  property real wheelAccumulator: 0

  implicitWidth: button.item ? button.item.implicitWidth : 0
  implicitHeight: button.item ? button.item.implicitHeight : 0

  Loader {
    id: button
    anchors.fill: parent
    sourceComponent: root.labelMode !== "none" && root.barLabel !== "" ? labelledButton : iconButton
  }

  Component {
    id: iconButton
    BarIconButton {
      anchors.fill: parent
      bar: root.bar
      text: root.glyph
      tooltipText: root.tooltip
      active: !!root.service && root.service.phase === "confirm"
      onPressed: function(b) { root.toggle() }
      onWheelMoved: function(delta) { root.wheelBrightness(delta) }
    }
  }

  Component {
    id: labelledButton
    WidgetButton {
      anchors.fill: parent
      bar: root.bar
      text: root.glyph + "  " + root.barLabel
      tooltipText: root.tooltip
      active: !!root.service && root.service.phase === "confirm"
      onPressed: function(b) { root.toggle() }
      onWheelMoved: function(delta) { root.wheelBrightness(delta) }
    }
  }

  // Scrolling over the icon changes the focused display's backlight, as on
  // the built-in widget.
  function wheelBrightness(delta) {
    if (!service || !service.focusedMonitor) return
    var wheel = Util.wheelSteps(wheelAccumulator, delta)
    wheelAccumulator = wheel.remainder
    if (wheel.steps === 0) return
    var name = service.focusedMonitor.name
    var current = service.brightness[name]
    if (current === undefined) { service.readBrightness(name); return }
    if (current < 0) return
    var p = service.setBacklight(name, current + wheel.steps * 5)
    if (bar && bar.shell) bar.shell.summon("omarchy.osd", JSON.stringify({ icon: "brightness", value: p }))
  }

  // ---------------------------------------------------------------- popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.textEditing

      onMoveRequested: function(dx, dy) {
        var v = viewLoader.item
        if (v && typeof v.handleMove === "function" && v.handleMove(dx, dy)) return
        if (dy !== 0) root.scrollBy(dy * Style.space(60))
        else if (dx !== 0) root.cycleTab(dx)
      }
      onActivateRequested: {
        var v = viewLoader.item
        if (v && typeof v.handleActivate === "function") v.handleActivate()
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var n = parseInt(t, 10)
        if (n >= 1 && n <= root.tabs.length) { root.tab = root.tabs[n - 1].value; return }
        if (t === "[") { root.cycleTab(-1); return }
        if (t === "]") { root.cycleTab(1); return }
        if (t === "i" && root.service) { root.service.identify(); return }
        var v = viewLoader.item
        if (v && typeof v.handleText === "function") v.handleText(t)
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: column.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: column
          width: scrollArea.availableWidth
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            title: "Displays"
            meta: {
              if (!root.service) return "STARTING…"
              var s = root.service
              var bits = [s.enabledCount + (s.enabledCount === 1 ? " DISPLAY" : " DISPLAYS")]
              if (s.activeProfile) bits.push(s.activeProfile.name.toUpperCase())
              else if (s.monitors.length > 1) bits.push("NOT SAVED")
              if (s.laptopMode) bits.push(Profiles.laptopModeLabel(s.laptopMode).toUpperCase())
              return bits.join(" · ")
            }
            iconComponent: Component {
              Text {
                text: root.glyph
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Button {
                text: "Identify"
                tooltipText: "Show each screen's number (I)"
                fontSize: Style.font.caption
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.identify()
              }
            }
          }

          Text {
            visible: !root.ready
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "The OmniDisplay service is not running yet. If this stays, run: omarchy restart shell"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // Errors and notes, newest first, until dismissed.
          Column {
            visible: root.ready && root.service.messages.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.ready ? root.service.messages : []
              Item {
                required property var modelData
                width: column.width
                implicitHeight: msgText.implicitHeight
                Text {
                  id: msgText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(28)
                  textFormat: Text.PlainText
                  wrapMode: Text.WordWrap
                  text: modelData.text
                  color: modelData.level === "error" ? Color.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
            PanelActionButton {
              anchors.right: parent.right
              iconText: "󰅖"
              tooltipText: "Dismiss"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.service.clearMessages()
            }
          }

          // OmniDisplay's block went missing from monitors.lua.
          BorderSurface {
            visible: root.ready && root.service.blockMissing
            width: parent.width
            height: blockCol.implicitHeight + Style.space(16)
            color: Util.alpha(Color.urgent, 0.10)
            borderSpec: Border.flat(Color.urgent, 1)
            radius: Style.cornerRadius

            Column {
              id: blockCol
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.margins: Style.space(10)
              spacing: Style.space(6)
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: "OmniDisplay's block is missing from monitors.lua (an Omarchy refresh resets the file). Until it is back, the layout is restored only once the shell is running."
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Row {
                anchors.right: parent.right
                spacing: Style.space(8)
                Button {
                  text: "Not now"
                  bordered: true
                  fontSize: Style.font.caption
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.service.blockNoticeDismissed = true
                }
                Button {
                  text: "Write it again"
                  bordered: true
                  active: true
                  fontSize: Style.font.caption
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.service.writeBlockNow()
                }
              }
            }
          }

          // The change waiting for Keep, also shown on every screen.
          BorderSurface {
            visible: root.ready && (root.service.phase === "confirm" || root.service.phase === "keeping")
            width: parent.width
            height: pendingRow.implicitHeight + Style.space(16)
            color: Util.alpha(Color.accent, 0.12)
            borderSpec: Border.flat(Color.accent, 1)
            radius: Style.cornerRadius

            Row {
              id: pendingRow
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)

              Text {
                width: parent.width - revertBtn.width - keepBtn.width - parent.spacing * 2
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.ready ? "Keep these settings? Reverting in " + root.service.remaining + " s" : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Button {
                id: revertBtn
                text: "Revert"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.service.revert()
              }
              Button {
                id: keepBtn
                text: "Keep"
                bordered: true
                active: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.service.keep(!root.service.keepFailed)
              }
            }
          }

          // Equal-width tabs, so all of them fit at any panel width.
          Row {
            id: tabBar
            visible: root.ready
            width: parent.width
            spacing: Style.spacing.xs
            readonly property real cell: (width - spacing * (root.tabs.length - 1)) / Math.max(1, root.tabs.length)

            Repeater {
              model: root.tabs
              Button {
                required property var modelData
                required property int index
                width: tabBar.cell
                text: modelData.label
                tooltipText: modelData.label + "  (" + (index + 1) + ")"
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.xs
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                active: root.tab === modelData.value
                onClicked: root.tab = modelData.value
              }
            }
          }

          Loader {
            id: viewLoader
            width: parent.width
            active: root.ready && root.opened
            sourceComponent: {
              switch (root.tab) {
              case "arrange": return arrangeView
              case "color": return colorView
              case "workspaces": return workspacesView
              case "profiles": return profilesView
              case "cast": return castView
              default: return basicsView
              }
            }
          }

          Item { width: 1; height: Style.space(4) }
        }
      }
    }
  }

  function scrollBy(delta) {
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var max = Math.max(0, column.implicitHeight - flick.height)
    flick.contentY = Math.max(0, Math.min(max, flick.contentY + delta))
  }

  function cycleTab(direction) {
    var i = 0
    for (var k = 0; k < tabs.length; k++) if (tabs[k].value === tab) i = k
    tab = tabs[(i + direction + tabs.length) % tabs.length].value
  }

  Component { id: basicsView; BasicsView { panel: root } }
  Component { id: arrangeView; ArrangeView { panel: root } }
  Component { id: colorView; ColorView { panel: root } }
  Component { id: workspacesView; WorkspacesView { panel: root } }
  Component { id: profilesView; ProfilesView { panel: root } }
  Component { id: castView; CastView { panel: root } }
}
