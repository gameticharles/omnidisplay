import QtQuick
import qs.Ui
import qs.Commons

// A panel section: separator, small-caps title with optional trailing note,
// then its rows. The rows are this item's children.
Column {
  id: root

  property string title: ""
  property string trailing: ""
  property bool separator: true
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  default property alias content: body.data

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  PanelSeparator {
    visible: root.separator
    foreground: root.foreground
  }

  Item {
    visible: root.title !== ""
    width: root.width
    implicitHeight: Math.max(header.implicitHeight, note.implicitHeight)

    PanelSectionHeader {
      id: header
      text: root.title
      foreground: root.foreground
      fontFamily: root.fontFamily
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: note
      textFormat: Text.PlainText
      text: root.trailing
      visible: text !== ""
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      elide: Text.ElideLeft
      width: Math.min(implicitWidth, root.width - header.implicitWidth - Style.space(12))
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  Column {
    id: body
    width: root.width
    spacing: Style.space(8)
  }
}
