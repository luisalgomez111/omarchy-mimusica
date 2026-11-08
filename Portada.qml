import QtQuick
import qs.Commons

// Carátula de un disco (o un glifo si no hay imagen).
Rectangle {
  id: portada
  property string archivo: ""
  property string glifo: "󰝚"
  property color fondo: "#333"
  property color colorGlifo: "#888"
  property string familia: Style.font.family

  radius: Style.spacing.labelGap
  color: fondo
  clip: true

  Image {
    id: img
    anchors.fill: parent
    source: portada.archivo ? "file://" + portada.archivo : ""
    sourceSize.width: Math.ceil(portada.width * 2)
    sourceSize.height: Math.ceil(portada.height * 2)
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    cache: true
    smooth: true
    visible: status === Image.Ready
  }

  Text {
    anchors.centerIn: parent
    visible: img.status !== Image.Ready
    textFormat: Text.PlainText
    text: portada.glifo
    color: portada.colorGlifo
    font.family: portada.familia
    font.pixelSize: Math.max(Style.font.caption, portada.height * 0.45)
  }
}
