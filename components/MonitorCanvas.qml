import QtQuick
import qs.Ui
import qs.Commons
import "../lib/Model.js" as Model
import "../lib/Layout.js" as Layout
import "../lib/Profiles.js" as Profiles

// The arrangement as a stage: every display on the desktop drawn as a lit
// screen at its logical size (mode over scale, rotation aware), on a quiet
// dot lattice. Only the selected screen is lit with the accent. Each card
// carries its connector, model and size, its mode, scale and position, and
// its workspaces as chips; when the workspace plan changes, the numbers that
// move glide from their old display to the new one.
//
// Drag a screen where it stands on the desk and it lands flush against the
// nearest free edge. With `interactive: false` and a `layout` given, it is a
// small picture (profile thumbnails, the keep card).
//
// The stage look and the chip glide follow crmne's hyprmoncfg panel (MIT);
// see NOTICE.
Item {
  id: canvas

  property var service: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool grabbed: false
  property bool interactive: true
  // A fixed layout to draw instead of the draft (thumbnails).
  property var layout: service ? service.draft.filter(Model.isArrangeable) : []
  property var workspacePlan: service ? Profiles.planWorkspaces(service.draft, service.draftWorkspaces) : []
  property bool compact: height < Style.space(150)
  property bool dotted: !compact
  // Per display name, a short note such as "Running at 60 Hz, saved 144 Hz".
  property var notes: ({})

  readonly property var fit: Layout.fitTransform(layout, width, height, compact ? Style.space(6) : Style.space(22))
  // Frozen while dragging, so cards do not rescale under the pointer.
  property var frozenFit: null
  readonly property var activeFit: frozenFit || fit
  property bool dragging: false

  function workspacesOn(name) {
    var out = []
    for (var i = 0; i < workspacePlan.length; i++) if (workspacePlan[i].name === name) out.push(workspacePlan[i].workspace)
    return out
  }

  // ------------------------------------------------------------ chip glide

  readonly property real chipSize: Math.max(Style.space(14), Style.font.caption * 1.45)
  readonly property real chipGap: Style.space(3)
  property var lastPlan: []
  property var travelling: []         // [{ workspace, fromX, fromY, toX, toY }]
  property var travellingIds: ({})

  // Each card registers its chip row so the glide starts and ends exactly on
  // the chips drawn (chips run left to right under the display's name).
  property var chipRows: ({})

  function chipPoint(name, index, count) {
    var row = chipRows[name]
    if (!row) return null
    var shown = Math.min(count, row.perRow)
    var slot = count > shown ? Math.min(index, shown - 1) : index
    var p = row.mapToItem(canvas, slot * (chipSize + chipGap), 0)
    return { x: p.x, y: p.y }
  }

  function chipPointFor(plan, workspace) {
    var name = ""
    for (var i = 0; i < plan.length; i++) if (plan[i].workspace === workspace) name = plan[i].name
    if (!name) return null
    var list = plan.filter(function(r) { return r.name === name }).map(function(r) { return r.workspace })
    return chipPoint(name, list.indexOf(workspace), list.length)
  }

  onWorkspacePlanChanged: {
    var before = lastPlan
    var after = workspacePlan
    lastPlan = after
    if (!interactive || dragging || compact || !before.length) return
    if (service && service.animationsEnabled === false) return
    var moves = Profiles.chipMoves(before, after)
    if (!moves.length || moves.length > 12) return
    var list = []
    var ids = {}
    for (var i = 0; i < moves.length; i++) {
      var a = chipPointFor(before, moves[i].workspace)
      var b = chipPointFor(after, moves[i].workspace)
      if (!a || !b) continue
      list.push({ workspace: moves[i].workspace, fromX: a.x, fromY: a.y, toX: b.x, toY: b.y })
      ids[String(moves[i].workspace)] = true
    }
    travellingIds = ids
    travelling = list
    glideDone.restart()
  }

  Timer {
    id: glideDone
    interval: 300
    onTriggered: { canvas.travelling = []; canvas.travellingIds = ({}) }
  }

  // ----------------------------------------------------------------- stage

  implicitHeight: Style.space(240)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius + Style.space(4)
    color: Util.alpha(canvas.foreground, 0.035)
    border.width: canvas.compact ? 0 : 1
    border.color: Util.alpha(canvas.foreground, 0.10)
  }

  // Spatial reference without a wireframe: a quiet dot lattice.
  Canvas {
    id: dots
    anchors.fill: parent
    visible: canvas.dotted
    property color dotColor: Util.alpha(canvas.foreground, 0.13)
    onDotColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.fillStyle = dotColor
      var step = Style.space(16)
      for (var y = step; y < height; y += step)
        for (var x = step; x < width; x += step)
          ctx.fillRect(x, y, 1.5, 1.5)
    }
  }

  Text {
    visible: canvas.layout.length === 0
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: "No display is on"
    color: Qt.darker(canvas.foreground, 1.4)
    font.family: canvas.fontFamily
    font.pixelSize: Style.font.body
  }

  Repeater {
    model: canvas.layout

    delegate: Item {
      id: card
      required property var modelData
      readonly property var size: Model.logicalSize(modelData)
      readonly property bool isSelected: !!canvas.service && modelData.name === canvas.service.selected
      readonly property var live: canvas.service ? Model.entryByName(canvas.service.monitors, modelData.name) : null
      readonly property bool changed: !!live && (live.x !== modelData.x || live.y !== modelData.y
                                                 || !Model.sameScale(live.scale, modelData.scale)
                                                 || live.width !== modelData.width || live.transform !== modelData.transform)
      readonly property var ws: canvas.workspacesOn(modelData.name)
      readonly property color lit: isSelected ? Color.accent : canvas.foreground
      readonly property bool roomy: height > Style.space(70) && width > Style.space(110)
      readonly property string note: canvas.notes[modelData.name] || ""
      // Too short for name, model, chips and the mode lines: drop the model.
      readonly property bool tight: ws.length > 0 && roomy && !canvas.compact
        && Style.space(8) + nameText.implicitHeight + modelText.implicitHeight + Style.space(6) + canvas.chipSize
           + Style.space(6) + bottomInfo.implicitHeight + Style.space(8) > height

      function homeX() { return canvas.activeFit.offsetX + modelData.x * canvas.activeFit.scale }
      function homeY() { return canvas.activeFit.offsetY + modelData.y * canvas.activeFit.scale }

      x: homeX()
      y: homeY()
      width: Math.max(Style.space(20), size.width * canvas.activeFit.scale - 3)
      height: Math.max(Style.space(14), size.height * canvas.activeFit.scale - 3)
      z: dragArea.drag.active ? 10 : (isSelected ? 2 : 1)

      // Contact shadow: the screen sits on the stage, not in it.
      Rectangle {
        visible: !canvas.compact
        x: Style.space(2)
        y: Style.space(4)
        width: parent.width
        height: parent.height
        radius: bezel.radius
        color: Qt.rgba(0, 0, 0, 0.28)
      }

      // The bezel, then the lit panel inside it.
      Rectangle {
        id: bezel
        anchors.fill: parent
        radius: Math.max(3, Style.cornerRadius + Style.space(2))
        color: Qt.tint(Color.background, Util.alpha(canvas.foreground, 0.10))
        border.width: card.isSelected ? Math.max(2, Style.space(2)) : 1
        border.color: card.isSelected ? Color.accent : Util.alpha(canvas.foreground, card.changed ? 0.6 : 0.28)
        opacity: dragArea.drag.active ? 0.88 : 1

        Rectangle {
          anchors.fill: parent
          anchors.margins: canvas.compact ? 2 : Style.space(4)
          radius: Math.max(2, bezel.radius - Style.space(2))
          gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(card.lit.r, card.lit.g, card.lit.b, card.isSelected ? 0.30 : 0.10) }
            GradientStop { position: 1.0; color: Qt.rgba(card.lit.r, card.lit.g, card.lit.b, card.isSelected ? 0.08 : 0.03) }
          }
        }
      }

      Rectangle {
        visible: canvas.grabbed && card.isSelected
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        radius: bezel.radius + Style.space(4)
        color: "transparent"
        border.width: 1
        border.color: Color.accent
      }

      // Connector, model and size.
      Column {
        visible: !canvas.compact || card.height > Style.space(30)
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: Style.space(10)
        anchors.topMargin: Style.space(8)
        width: parent.width - Style.space(20)
        spacing: Style.space(1)
        Text {
          id: nameText
          width: parent.width
          textFormat: Text.PlainText
          text: (canvas.service && canvas.service.displayNumber(card.modelData.name) ? canvas.service.displayNumber(card.modelData.name) + " · " : "")
                + card.modelData.name
          color: card.isSelected ? Color.accent : canvas.foreground
          font.family: canvas.fontFamily
          font.pixelSize: canvas.compact ? Style.font.caption : Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }
        Text {
          id: modelText
          visible: card.roomy && !card.tight
          width: parent.width
          textFormat: Text.PlainText
          text: Model.displayLabel(card.modelData) + (Model.inchesLabel(card.modelData) ? " " + Model.inchesLabel(card.modelData) : "")
          color: Qt.darker(canvas.foreground, 1.25)
          font.family: canvas.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // Mode, scale and position, and any note on how it really runs.
      Column {
        id: bottomInfo
        visible: card.roomy && !canvas.compact
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: Style.space(10)
        anchors.bottomMargin: Style.space(8)
        width: parent.width - Style.space(20)
        spacing: Style.space(1)
        Text {
          visible: card.note !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: card.note
          color: Color.urgent
          font.family: canvas.fontFamily
          font.pixelSize: Style.font.caption
          font.italic: true
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: card.modelData.width + "x" + card.modelData.height + "@" + Model.formatRefresh(card.modelData.refresh) + "Hz"
                + (card.modelData.transform ? "  " + Model.transformLabel(card.modelData.transform) : "")
          color: Qt.darker(canvas.foreground, 1.15)
          font.family: canvas.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "Scale " + Model.normalizeScale(card.modelData.scale) + "x   Position " + card.modelData.x + "," + card.modelData.y
          color: Qt.darker(canvas.foreground, 1.45)
          font.family: canvas.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // Workspace chips, in a row under the name; a long list ends in +N.
      Row {
        id: chips
        readonly property int perRow: Math.max(1, Math.floor((card.width - Style.space(20) + canvas.chipGap) / (canvas.chipSize + canvas.chipGap)))
        readonly property int extra: card.ws.length > perRow ? card.ws.length - perRow + 1 : 0
        visible: card.ws.length > 0 && card.height > Style.space(26)
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        y: Style.space(8) + nameText.height + (modelText.visible ? modelText.height : 0) + Style.space(6)
        spacing: canvas.chipGap
        Component.onCompleted: canvas.chipRows[card.modelData.name] = chips
        Component.onDestruction: if (canvas.chipRows[card.modelData.name] === chips) delete canvas.chipRows[card.modelData.name]
        Repeater {
          model: chips.extra ? card.ws.slice(0, chips.perRow - 1).concat(["+" + chips.extra]) : card.ws
          Rectangle {
            required property var modelData
            readonly property bool more: String(modelData).charAt(0) === "+"
            width: more ? Math.max(canvas.chipSize, moreText.implicitWidth + Style.space(6)) : canvas.chipSize
            height: canvas.chipSize
            radius: Math.max(2, Style.cornerRadius)
            color: more ? "transparent" : Util.alpha(Color.accent, card.isSelected ? 0.85 : 0.55)
            border.width: more ? 1 : 0
            border.color: Util.alpha(Color.accent, 0.6)
            opacity: canvas.travellingIds[String(modelData)] === true ? 0 : 1
            Text {
              id: moreText
              anchors.centerIn: parent
              text: String(parent.modelData)
              color: parent.more ? Color.accent : Color.background
              font.family: canvas.fontFamily
              font.pixelSize: Math.max(8, Style.font.caption * 0.85)
              font.bold: true
            }
          }
        }
      }

      MouseArea {
        id: dragArea
        anchors.fill: parent
        enabled: canvas.interactive && !!canvas.service
        hoverEnabled: true
        cursorShape: dragArea.drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        drag.target: card
        drag.threshold: 4
        onPressed: {
          canvas.service.select(card.modelData.name)
          canvas.frozenFit = canvas.fit
          canvas.dragging = true
        }
        onReleased: {
          var f = canvas.activeFit
          if (dragArea.drag.active || card.x !== card.homeX() || card.y !== card.homeY()) {
            canvas.service.drop(card.modelData.name, Math.round((card.x - f.offsetX) / f.scale), Math.round((card.y - f.offsetY) / f.scale))
          }
          canvas.frozenFit = null
          canvas.dragging = false
          card.x = Qt.binding(function() { return card.homeX() })
          card.y = Qt.binding(function() { return card.homeY() })
        }
      }
    }
  }

  // Chips on their way to a new display.
  Repeater {
    model: canvas.travelling
    Rectangle {
      id: ghost
      required property var modelData
      z: 20
      width: canvas.chipSize
      height: canvas.chipSize
      radius: Math.max(2, Style.cornerRadius)
      color: Util.alpha(Color.accent, 0.9)
      x: modelData.fromX
      y: modelData.fromY
      Text {
        anchors.centerIn: parent
        text: String(ghost.modelData.workspace)
        color: Color.background
        font.family: canvas.fontFamily
        font.pixelSize: Math.max(8, Style.font.caption * 0.85)
        font.bold: true
      }
      Component.onCompleted: glide.start()
      ParallelAnimation {
        id: glide
        NumberAnimation { target: ghost; property: "x"; to: ghost.modelData.toX; duration: 250; easing.type: Easing.InOutCubic }
        NumberAnimation { target: ghost; property: "y"; to: ghost.modelData.toY; duration: 250; easing.type: Easing.InOutCubic }
      }
    }
  }
}
