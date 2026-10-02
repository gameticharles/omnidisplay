import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import "../lib/Cast.js" as Cast
import "../components"

// The Cast tab. Wireless displays (Miracast through waycast, AirPlay
// through doubletake) with a Mirror/Extend choice per receiver, after
// Filippo Veneri's omarchy-wireless-display (MIT); and tablets or phones as
// a screen over VNC (wayvnc), local only unless network access is chosen,
// which always means TLS and a password.
Column {
  id: view

  required property var panel
  readonly property var service: panel.service
  readonly property color fg: panel.foreground
  readonly property string ff: panel.fontFamily
  readonly property color dim: panel.dim

  readonly property var cast: service.castState
  readonly property var displays: Cast.displays(cast)
  readonly property bool busy: Cast.isBusy(cast)
  readonly property var vnc: service.vncState

  property var pairModes: ({})
  property string credentialId: ""
  property bool rescanConfirm: false

  width: parent ? parent.width : 0
  spacing: Style.space(12)

  function modeFor(id) { return pairModes[id] === "extend" ? "extend" : "mirror" }
  function setModeFor(id, mode) {
    var next = {}
    for (var k in pairModes) next[k] = pairModes[k]
    next[id] = mode
    pairModes = next
  }

  readonly property string credentialWanted: Cast.awaitingCredential(cast)
  onCredentialWantedChanged: if (credentialWanted !== "") credentialId = credentialWanted

  // Opening looks for displays only when the list is empty; closing stops
  // the radio scanning in the background.
  Component.onCompleted: {
    service.readVnc()
    if (displays.length === 0) service.castCommand(["scan-start"])
  }
  Component.onDestruction: {
    panel.textEditing = false
    if (!Cast.hasConnected(view.service.castState)) view.service.castCommand(["scan-stop"])
  }

  function copyInstall(command) {
    service.run(["wl-copy"], command)
    Quickshell.execDetached(["omarchy-notification-send", "-g", "󰆏", "Install command copied", command])
  }

  // ------------------------------------------------------------ wireless

  Section {
    separator: false
    title: "WIRELESS DISPLAYS"
    trailing: Cast.headerSubtitle(view.cast).toUpperCase()
    foreground: view.fg
    fontFamily: view.ff

    // Errors stay until dismissed; notices are dimmed.
    Column {
      visible: Cast.errorLines(view.cast).length > 0 || view.cast.notice !== ""
      width: parent.width
      spacing: Style.space(4)
      Repeater {
        model: Cast.errorLines(view.cast)
        Text {
          required property string modelData
          width: view.width - Style.space(60)
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: modelData
          color: Color.urgent
          font.family: view.ff
          font.pixelSize: Style.font.caption
        }
      }
      Text {
        visible: view.cast.notice !== ""
        width: view.width - Style.space(60)
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: view.cast.notice
        color: view.dim
        font.family: view.ff
        font.pixelSize: Style.font.caption
      }
      Row {
        anchors.right: parent.right
        PanelActionButton {
          iconText: "󰆏"
          tooltipText: "Copy the messages"
          foreground: view.fg
          onClicked: view.service.run(["wl-copy"], Cast.messagesText(view.cast))
        }
        PanelActionButton {
          iconText: "󰅖"
          tooltipText: "Dismiss"
          foreground: view.fg
          onClicked: view.service.castCommand(["clear-errors"])
        }
      }
    }

    Repeater {
      model: Cast.missingBackends(view.cast)
      Text {
        required property var modelData
        width: view.width
        textFormat: Text.PlainText
        text: Cast.missingBackendText(modelData) + "  (click to copy)"
        color: view.dim
        font.family: view.ff
        font.pixelSize: Style.font.caption
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: view.copyInstall(Cast.installCommand(parent.modelData.pkg))
        }
      }
    }

    Repeater {
      model: view.displays

      CursorSurface {
        id: row
        required property var modelData
        readonly property bool live: modelData.connected || modelData.pending
        readonly property bool modal: Cast.supportsExtend(modelData.protocol, view.cast)
        readonly property string mode: live && modelData.mode ? modelData.mode : view.modeFor(modelData.id)
        readonly property bool expanded: view.credentialId === modelData.id
        width: view.width
        implicitHeight: rowCol.implicitHeight + Style.space(12)
        current: modelData.connected
        foreground: view.fg

        Column {
          id: rowCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(6)
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(labels.implicitHeight, controls.implicitHeight)

            Column {
              id: labels
              anchors.left: parent.left
              anchors.right: controls.left
              anchors.verticalCenter: parent.verticalCenter
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: row.modelData.name
                color: view.fg
                font.family: view.ff
                font.pixelSize: Style.font.body
                font.bold: row.modelData.connected
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: row.modelData.connected ? Cast.displayDetail(row.modelData) : Cast.displaySubtitle(row.modelData) + (row.modelData.pending ? " · connecting…" : "")
                color: view.dim
                font.family: view.ff
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Row {
              id: controls
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Text {
                visible: row.modal
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "EXTEND"
                color: view.dim
                font.family: view.ff
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              ToggleSwitch {
                visible: row.modal
                anchors.verticalCenter: parent.verticalCenter
                trackHeight: Math.round(Style.font.caption * 1.3)
                cursorPad: Style.space(3)
                checked: row.mode === "extend"
                busy: row.live
                foreground: view.fg
                onToggled: view.setModeFor(row.modelData.id, row.mode === "extend" ? "mirror" : "extend")
              }
              PanelActionButton {
                visible: !row.modelData.connected
                iconText: "󰌷"
                tooltipText: row.modelData.pending ? "Connecting…" : (row.mode === "extend" ? "Connect, extending onto it" : "Connect, mirroring onto it")
                foreground: view.busy ? view.dim : view.fg
                onClicked: if (!view.busy) view.service.castCommand(["connect", row.modelData.id, view.modeFor(row.modelData.id)])
              }
              PanelActionButton {
                visible: row.modelData.connected
                iconText: "󰅙"
                tooltipText: "Disconnect"
                foreground: view.fg
                onClicked: view.service.castCommand(["disconnect", row.modelData.id])
              }
            }
          }

          // PIN or password, typed into the row that asked for it. It goes
          // to the backend over stdin, never as an argument.
          Row {
            visible: row.expanded
            width: parent.width
            spacing: Style.space(6)
            TextField {
              id: credentialField
              width: parent.width - send.width - parent.spacing
              password: true
              placeholderText: Cast.credentialLabel(row.modelData.awaiting)
              foreground: view.fg
              onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
              onActiveFocusChanged: view.panel.textEditing = activeFocus
              onAccepted: send.clicked()
              Keys.onEscapePressed: {
                view.credentialId = ""
                view.panel.textEditing = false
                view.service.castCommand(["disconnect", row.modelData.id])
              }
            }
            PanelActionButton {
              id: send
              iconText: "󰄬"
              tooltipText: "Send"
              foreground: view.fg
              onClicked: {
                if (credentialField.text === "") return
                var secret = credentialField.text
                credentialField.text = ""
                view.credentialId = ""
                view.panel.textEditing = false
                view.service.castCommand(["credential", row.modelData.id], secret + "\n")
              }
            }
          }
          Text {
            visible: row.expanded
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: Cast.credentialHint(row.modelData.awaiting)
            color: view.dim
            font.family: view.ff
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    Row {
      anchors.right: parent.right
      spacing: Style.space(8)
      Text {
        visible: view.rescanConfirm
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "Searching ends the session."
        color: Color.urgent
        font.family: view.ff
        font.pixelSize: Style.font.caption
      }
      Button {
        text: view.rescanConfirm ? "Search anyway" : (view.cast.status === "discovering" ? "Searching…" : "Search again")
        bordered: true
        foreground: view.fg
        fontFamily: view.ff
        enabled: view.cast.status !== "discovering" && !view.busy
        onClicked: {
          if (Cast.hasConnected(view.cast) && !view.rescanConfirm) { view.rescanConfirm = true; return }
          view.rescanConfirm = false
          view.service.castCommand(["rescan"])
        }
      }
    }
  }

  // ----------------------------------------------------- show one window

  // Casts carry whole screens. To show one window, it moves onto the cast
  // (or tablet) screen and goes fullscreen there; Return puts it back.
  property string pickedWindow: ""

  Section {
    visible: view.service.castTargets.length > 0 || Object.keys(view.service.sentWindows).length > 0
    title: "SHOW ONE WINDOW"
    trailing: view.service.castTargets.length ? "ON " + view.service.castTargets.join(", ") : ""
    foreground: view.fg
    fontFamily: view.ff

    Component.onCompleted: view.service.loadWindows()

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Extended casts and tablet screens show their own workspace. Send a window there and it fills the screen; your own screen keeps the rest."
      color: view.dim
      font.family: view.ff
      font.pixelSize: Style.font.caption
    }

    Row {
      visible: view.service.castTargets.length > 0
      width: parent.width
      spacing: Style.space(6)
      Dropdown {
        width: parent.width - sendBtn.width - refreshWin.width - parent.spacing * 2
        showLabel: false
        foreground: view.fg
        fontFamily: view.ff
        value: view.pickedWindow
        options: view.service.windows.filter(function(w) { return !view.service.sentWindows[w.address] }).map(function(w) {
          return { value: w.address, label: (w.title || w["class"]) + "  ·  " + w["class"] }
        })
        onChanged: function(v) { view.pickedWindow = v }
      }
      PanelActionButton {
        id: refreshWin
        iconText: "󰑓"
        tooltipText: "Refresh the list"
        foreground: view.fg
        onClicked: view.service.loadWindows()
      }
      Button {
        id: sendBtn
        text: "Send"
        bordered: true
        fontSize: Style.font.caption
        foreground: view.fg
        fontFamily: view.ff
        onClicked: if (view.pickedWindow) { view.service.sendWindow(view.pickedWindow, view.service.castTargets[0]); view.pickedWindow = "" }
      }
    }

    Repeater {
      model: Object.keys(view.service.sentWindows)
      FieldRow {
        required property string modelData
        label: view.service.sentWindows[modelData] ? view.service.sentWindows[modelData].title : ""
        hint: view.service.sentWindows[modelData] ? "on " + view.service.sentWindows[modelData].output : ""
        labelRatio: 0.7
        foreground: view.fg
        fontFamily: view.ff
        Button {
          anchors.right: parent.right
          text: "Return"
          bordered: true
          fontSize: Style.font.caption
          foreground: view.fg
          fontFamily: view.ff
          onClicked: view.service.returnWindow(modelData)
        }
      }
    }
  }

  // --------------------------------------------------------------- tablet

  // Opens with what was used last (kept in the profiles store).
  readonly property var tabletPrefs: (service.prefs && service.prefs.tablet) || ({})
  property string tabletMode: tabletPrefs.mode || "extend"
  property string tabletSize: tabletPrefs.size || "1920x1200@60"
  property string tabletSide: tabletPrefs.side || "right"
  property string tabletAccess: tabletPrefs.access || "local"

  function startTablet() {
    service.setTabletPrefs({ mode: tabletMode, size: tabletSize, side: tabletSide, access: tabletAccess })
    service.vncStart(tabletMode, tabletSize, tabletSide, tabletAccess)
  }

  function sizeFrom(text) {
    var m = /^\s*(\d{3,4})\s*[x×]\s*(\d{3,4})(?:\s*@\s*(\d{2,3}))?\s*$/.exec(String(text || ""))
    if (!m) return ""
    var w = Number(m[1]), h = Number(m[2])
    if (w < 320 || w > 7680 || h < 200 || h > 4320) return ""
    return w + "x" + h + "@" + (m[3] || "60")
  }

  Section {
    title: "TABLET OR PHONE AS A SCREEN"
    trailing: view.vnc.running ? "RUNNING" : ""
    foreground: view.fg
    fontFamily: view.ff

    Text {
      visible: !view.vnc.installed
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Needs wayvnc. Click to copy the install command: omarchy pkg add wayvnc"
      color: view.dim
      font.family: view.ff
      font.pixelSize: Style.font.caption
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: view.copyInstall("omarchy pkg add wayvnc")
      }
    }

    Column {
      visible: view.vnc.installed && !view.vnc.running
      width: parent.width
      spacing: Style.space(8)

      FieldRow {
        label: "Show"
        foreground: view.fg
        fontFamily: view.ff
        ButtonGroup {
          anchors.right: parent.right
          options: [{ value: "extend", label: "A new screen" }, { value: "mirror", label: "This screen" }]
          value: view.tabletMode
          foreground: view.fg
          fontFamily: view.ff
          fontSize: Style.font.caption
          focusable: false
          onChanged: function(v) { view.tabletMode = v }
        }
      }
      FieldRow {
        visible: view.tabletMode === "extend"
        label: "Size"
        foreground: view.fg
        fontFamily: view.ff
        Dropdown {
          width: parent.width
          showLabel: false
          foreground: view.fg
          fontFamily: view.ff
          value: view.tabletSize
          options: [
            { value: "1920x1200@60", label: "Tablet 1920 × 1200" },
            { value: "2048x1536@60", label: "iPad 2048 × 1536" },
            { value: "2560x1600@60", label: "Tablet 2560 × 1600" },
            { value: "1280x800@60", label: "Small tablet 1280 × 800" },
            { value: "1080x2340@60", label: "Phone, portrait" },
            { value: "1920x1080@60", label: "1920 × 1080" }
          ]
          onChanged: function(v) { view.tabletSize = v }
        }
      }
      FieldRow {
        visible: view.tabletMode === "extend"
        label: "Custom size"
        hint: "320×200 up to 7680×4320"
        foreground: view.fg
        fontFamily: view.ff
        TextField {
          width: parent.width
          placeholderText: view.tabletSize
          foreground: view.fg
          onActiveFocusChanged: view.panel.textEditing = activeFocus
          onAccepted: {
            var size = view.sizeFrom(text)
            if (!size) { view.service.say("error", "Type a size like 2560x1600"); return }
            view.tabletSize = size
            text = ""
            focus = false
            view.panel.textEditing = false
          }
          Keys.onEscapePressed: { text = ""; focus = false; view.panel.textEditing = false }
        }
      }
      FieldRow {
        visible: view.tabletMode === "extend"
        label: "Place it"
        foreground: view.fg
        fontFamily: view.ff
        ButtonGroup {
          anchors.right: parent.right
          options: ["left", "right", "above", "below"]
          value: view.tabletSide
          foreground: view.fg
          fontFamily: view.ff
          fontSize: Style.font.caption
          focusable: false
          onChanged: function(v) { view.tabletSide = v }
        }
      }
      FieldRow {
        label: "Access"
        hint: view.tabletAccess === "local" ? "This computer only; reach it over an SSH tunnel" : "Your network, with TLS and a password"
        foreground: view.fg
        fontFamily: view.ff
        ButtonGroup {
          anchors.right: parent.right
          options: [{ value: "local", label: "Local" }, { value: "network", label: "Network" }]
          value: view.tabletAccess
          foreground: view.fg
          fontFamily: view.ff
          fontSize: Style.font.caption
          focusable: false
          onChanged: function(v) { view.tabletAccess = v }
        }
      }
      Button {
        anchors.right: parent.right
        text: "Start"
        bordered: true
        active: true
        foreground: view.fg
        fontFamily: view.ff
        onClicked: view.startTablet()
      }
    }

    Column {
      visible: view.vnc.running
      width: parent.width
      spacing: Style.space(8)

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: {
          var s = view.vnc.session || {}
          var where = s.access === "network"
            ? view.vnc.addresses.map(function(a) { return (a.kind || "") + " " + a.address + ":" + view.vnc.port + " (" + a.interface + ")" }).join(", ")
            : "127.0.0.1:" + view.vnc.port + " (SSH tunnel)"
          return (s.mode === "extend" ? "Serving the new screen " + (s.output || "") : "Serving " + (s.output || "this screen")) + " at " + where
        }
        color: view.fg
        font.family: view.ff
        font.pixelSize: Style.font.body
      }
      FieldRow {
        visible: !!view.vnc.password
        label: "Username"
        foreground: view.fg
        fontFamily: view.ff
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: view.vnc.username
          color: view.fg
          font.family: "monospace"
          font.pixelSize: Style.font.body
        }
      }
      FieldRow {
        id: passRow
        visible: !!view.vnc.password
        label: "Password"
        property bool shown: false
        foreground: view.fg
        fontFamily: view.ff
        Row {
          anchors.right: parent.right
          spacing: Style.space(4)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: passRow.shown ? view.vnc.password : "••••••••"
            color: view.fg
            font.family: "monospace"
            font.pixelSize: Style.font.body
          }
          PanelActionButton {
            iconText: passRow.shown ? "󰈉" : "󰈈"
            tooltipText: passRow.shown ? "Hide" : "Show"
            foreground: view.fg
            onClicked: passRow.shown = !passRow.shown
          }
          PanelActionButton {
            iconText: "󰆏"
            tooltipText: "Copy"
            foreground: view.fg
            onClicked: view.service.run(["wl-copy"], view.vnc.password)
          }
          PanelActionButton {
            iconText: "󰑓"
            tooltipText: "New password (the running session restarts with it)"
            foreground: view.fg
            onClicked: view.service.vncRegenerate()
          }
        }
      }
      Image {
        visible: !!view.vnc.password && view.service.qrPath !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        width: Style.space(150)
        height: width
        smooth: false
        cache: false
        source: view.service.qrPath !== "" ? "file://" + view.service.qrPath + "?" + view.service.qrRevision : ""
      }
      Text {
        visible: !!view.vnc.password
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: "Scan with a VNC app on the tablet (the code holds only the address). If it cannot connect, allow TCP port " + view.vnc.port + " from your local network in your firewall."
        color: view.dim
        font.family: view.ff
        font.pixelSize: Style.font.caption
      }
      Button {
        anchors.right: parent.right
        text: "Stop"
        bordered: true
        foreground: view.fg
        fontFamily: view.ff
        onClicked: view.service.vncStop()
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: view.vnc.listening ? "● Listening" : "○ Not listening yet: wayvnc may have failed to bind the port"
        color: view.vnc.listening ? view.fg : Color.urgent
        font.family: view.ff
        font.pixelSize: Style.font.caption
      }

      FieldRow {
        visible: (view.vnc.session || {}).access !== "network" && !!view.vnc.ssh
        label: "From another computer"
        hint: "Run this there, then connect its VNC client to localhost:" + view.vnc.port
        labelRatio: 0.4
        foreground: view.fg
        fontFamily: view.ff
        Row {
          width: parent.width
          spacing: Style.space(4)
          Text {
            width: parent.width - copySsh.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: view.vnc.ssh || ""
            color: view.fg
            font.family: "monospace"
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          PanelActionButton {
            id: copySsh
            iconText: "󰆏"
            tooltipText: "Copy"
            foreground: view.fg
            onClicked: view.service.run(["wl-copy"], view.vnc.ssh)
          }
        }
      }

      FieldRow {
        visible: (view.vnc.session || {}).mode === "extend"
        label: "Change size"
        foreground: view.fg
        fontFamily: view.ff
        TextField {
          width: parent.width
          placeholderText: (view.vnc.session || {}).size || ""
          foreground: view.fg
          onActiveFocusChanged: view.panel.textEditing = activeFocus
          onAccepted: {
            var size = view.sizeFrom(text)
            if (!size) { view.service.say("error", "Type a size like 2560x1600"); return }
            view.service.vncResize(size)
            text = ""
            focus = false
            view.panel.textEditing = false
          }
          Keys.onEscapePressed: { text = ""; focus = false; view.panel.textEditing = false }
        }
      }
    }
  }
}
