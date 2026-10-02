import QtQuick
import qs.Commons

// Label on the left, control on the right. The control is this item's
// child and should take `width: parent.width`.
Item {
  id: root

  property string label: ""
  property string hint: ""
  property real labelRatio: 0.34
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  default property alias content: slot.data

  width: parent ? parent.width : 0
  implicitHeight: Math.max(labels.implicitHeight, slot.childrenRect.height)

  Column {
    id: labels
    width: Math.round(root.width * root.labelRatio)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
    Text {
      width: parent.width
      visible: root.hint !== ""
      textFormat: Text.PlainText
      text: root.hint
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  Item {
    id: slot
    anchors.left: labels.right
    anchors.leftMargin: Style.space(8)
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    height: childrenRect.height
  }
}
