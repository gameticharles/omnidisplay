import QtQuick
import qs.Ui
import qs.Commons
import "../lib/Model.js" as Model
import "../lib/Layout.js" as Layout
import "../lib/Profiles.js" as Profiles

// The arrangement: every display on the desktop as a tile at its logical
// size (mode over scale, rotation aware). Drag one where it stands on the
// desk and it lands flush against the nearest free edge. The numbers match
// Identify. Workspace numbers from the plan sit along the bottom.
Item {
  id: canvas

  required property var service
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool grabbed: false

  readonly property var layout: service.draft.filter(Model.isArrangeable)
  readonly property var fit: Layout.fitTransform(layout, width, height, Style.space(18))
  // The fit is frozen while dragging, so tiles do not rescale under the pointer.
  property var frozenFit: null
  readonly property var activeFit: frozenFit || fit
  readonly property var workspacePlan: Profiles.planWorkspaces(service.draft, service.draftWorkspaces)

  function workspacesOn(name) {
    var out = []
    for (var i = 0; i < workspacePlan.length; i++) if (workspacePlan[i].name === name) out.push(workspacePlan[i].workspace)
    return out
  }

  implicitHeight: Style.space(230)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Util.alpha(canvas.foreground, 0.035)
    border.width: 1
    border.color: Util.alpha(canvas.foreground, 0.12)
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

    delegate: Rectangle {
      id: tile
      required property var modelData
      readonly property var size: Model.logicalSize(modelData)
      readonly property bool isSelected: modelData.name === canvas.service.selected
      readonly property var live: Model.entryByName(canvas.service.monitors, modelData.name)
      readonly property bool changed: !!live && (live.x !== modelData.x || live.y !== modelData.y
                                                 || !Model.sameScale(live.scale, modelData.scale)
                                                 || live.width !== modelData.width || live.transform !== modelData.transform)
      readonly property var ws: canvas.workspacesOn(modelData.name)

      function homeX() { return canvas.activeFit.offsetX + modelData.x * canvas.activeFit.scale }
      function homeY() { return canvas.activeFit.offsetY + modelData.y * canvas.activeFit.scale }

      x: homeX()
      y: homeY()
      width: Math.max(Style.space(24), size.width * canvas.activeFit.scale - 2)
      height: Math.max(Style.space(18), size.height * canvas.activeFit.scale - 2)
      radius: Math.max(2, Style.cornerRadius)
      z: dragArea.drag.active ? 10 : (isSelected ? 2 : 1)
      color: isSelected ? Util.alpha(Color.accent, 0.24) : Util.alpha(canvas.foreground, 0.09)
      border.width: isSelected ? Math.max(2, Style.space(2)) : 1
      border.color: isSelected ? Color.accent : Util.alpha(canvas.foreground, changed ? 0.7 : 0.35)
      opacity: dragArea.drag.active ? 0.85 : 1

      Rectangle {
        visible: canvas.grabbed && tile.isSelected
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        radius: tile.radius + Style.space(4)
        color: "transparent"
        border.width: 1
        border.color: Color.accent
      }

      Column {
        anchors.centerIn: parent
        width: parent.width - Style.space(8)
        spacing: 0

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: String(canvas.service.displayNumber(tile.modelData.name) || "")
          color: tile.isSelected ? Color.accent : canvas.foreground
          font.family: canvas.fontFamily
          font.pixelSize: Math.min(Style.font.display * 1.4, tile.height * 0.32)
          font.bold: true
        }
        Text {
          width: parent.width
          visible: tile.height > Style.space(56)
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: Model.displayLabel(tile.modelData)
          color: canvas.foreground
          font.family: canvas.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          visible: tile.height > Style.space(72)
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: tile.modelData.width + "×" + tile.modelData.height + " · " + Model.normalizeScale(tile.modelData.scale) + "x"
                + (tile.modelData.transform ? " · " + Model.transformLabel(tile.modelData.transform) : "")
          color: Qt.darker(canvas.foreground, 1.4)
          font.family: canvas.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        visible: tile.ws.length > 0 && tile.height > Style.space(40)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(3)
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(2)
        Repeater {
          model: tile.ws.slice(0, 8)
          Rectangle {
            required property var modelData
            width: Style.space(14)
            height: Style.space(13)
            radius: 2
            color: Util.alpha(Color.accent, 0.3)
            Text {
              anchors.centerIn: parent
              text: String(parent.modelData)
              color: canvas.foreground
              font.family: canvas.fontFamily
              font.pixelSize: Math.max(8, Style.font.caption * 0.8)
            }
          }
        }
      }

      MouseArea {
        id: dragArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: dragArea.drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        drag.target: tile
        drag.threshold: 4
        onPressed: {
          canvas.service.select(tile.modelData.name)
          canvas.frozenFit = canvas.fit
        }
        onReleased: {
          var f = canvas.activeFit
          if (dragArea.drag.active || tile.x !== tile.homeX() || tile.y !== tile.homeY()) {
            var lx = (tile.x - f.offsetX) / f.scale
            var ly = (tile.y - f.offsetY) / f.scale
            canvas.service.drop(tile.modelData.name, Math.round(lx), Math.round(ly))
          }
          canvas.frozenFit = null
          tile.x = Qt.binding(function() { return tile.homeX() })
          tile.y = Qt.binding(function() { return tile.homeY() })
        }
      }
    }
  }
}
