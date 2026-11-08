import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Mi música: reproduce ~/Music con mpv desde la barra.
// mpv corre aparte (sigue sonando si el shell se recarga) y se controla por su
// socket JSON IPC. biblioteca.py lee las etiquetas ID3 y las carátulas; el
// panel organiza por canciones, álbumes, artistas y géneros, y la cola que se
// manda a mpv es la lista que se está viendo.
Panel {
  id: root
  moduleName: "io.github.luisalgomez111.mimusica"
  ipcTarget: "io.github.luisalgomez111.mimusica"

  readonly property string runDir: Quickshell.env("XDG_RUNTIME_DIR") + "/mimusica"
  readonly property string socketPath: runDir + "/mpv.sock"
  readonly property string cacheDir: Quickshell.env("HOME") + "/.cache/mimusica"
  readonly property string musicDir: Quickshell.env("HOME") + "/Music"
  readonly property string scriptPath: Qt.resolvedUrl("biblioteca.py").toString().replace(/^file:\/\//, "")

  // ---------- biblioteca ----------
  property var canciones: []      // [{t,a,aa,al,n,d,y,g,p,c,k}]
  property var porRuta: ({})      // ruta → índice
  property var albumes: []        // grupos: {titulo, sub, c, k, indices, tipo}
  property var artistas: []
  property var generos: []
  property bool cargando: true

  // ---------- navegación ----------
  readonly property var pestanas: ["Canciones", "Álbumes", "Artistas", "Géneros"]
  property int pestana: 0
  property var grupo: null        // grupo abierto (detalle) o null
  property string filtro: ""
  property int seleccion: 0
  property var elementos: []      // lo que muestra la lista

  // ---------- estado de mpv ----------
  property bool pausado: true
  property bool inactivo: true
  property string ruta: ""
  property string archivo: ""
  property real posicion: 0
  property real duracion: 0
  property real volumen: 70
  property bool aleatorio: false
  property var pendientes: []

  readonly property bool sonando: !inactivo && ruta !== ""
  readonly property int actual: sonando && porRuta[ruta] !== undefined ? porRuta[ruta] : -1
  readonly property var cancionActual: actual >= 0 ? canciones[actual] : null
  readonly property string titulo: cancionActual ? cancionActual.t : archivo
  readonly property string artista: cancionActual ? cancionActual.a : ""

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color barFg: bar ? bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property color acento: Commons.Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function tiempo(s) {
    if (!(s > 0)) return "0:00"
    s = Math.floor(s)
    var m = Math.floor(s / 60), r = s % 60
    return m + ":" + (r < 10 ? "0" : "") + r
  }

  function sinAcentos(t) {
    return String(t).normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase()
  }

  // ---------- carga ----------
  function cargarBiblioteca(texto) {
    var lista
    try { lista = JSON.parse(texto) } catch (e) { lista = []; console.warn("mimusica: biblioteca ilegible") }
    if (!Array.isArray(lista)) lista = []

    var rutas = {}, alb = {}, art = {}, gen = {}
    var ordenAlb = [], ordenArt = [], ordenGen = []
    for (var i = 0; i < lista.length; i++) {
      var s = lista[i]
      rutas[s.p] = i
      var ka = s.aa + "\u0001" + s.al
      if (!alb[ka]) { alb[ka] = { tipo: "album", titulo: s.al, artista: s.aa, y: s.y, c: s.c, indices: [] }; ordenAlb.push(ka) }
      alb[ka].indices.push(i)
      if (!alb[ka].c && s.c) alb[ka].c = s.c
      if (!art[s.aa]) { art[s.aa] = { tipo: "artista", titulo: s.aa, c: s.c, indices: [], discos: {} }; ordenArt.push(s.aa) }
      art[s.aa].indices.push(i)
      art[s.aa].discos[s.al] = true
      if (!art[s.aa].c && s.c) art[s.aa].c = s.c
      var g = s.g || "Sin género"
      if (!gen[g]) { gen[g] = { tipo: "genero", titulo: g, c: "", indices: [] }; ordenGen.push(g) }
      gen[g].indices.push(i)
    }

    function contar(n) { return n + (n === 1 ? " canción" : " canciones") }
    var a1 = ordenAlb.map(function(k) {
      var x = alb[k]
      x.sub = x.artista + (x.y ? " · " + x.y : "") + " · " + contar(x.indices.length)
      x.k = sinAcentos(x.titulo + " " + x.artista)
      return x
    })
    var a2 = ordenArt.map(function(k) {
      var x = art[k], nd = Object.keys(x.discos).length
      x.sub = nd + (nd === 1 ? " disco" : " discos") + " · " + contar(x.indices.length)
      x.k = sinAcentos(x.titulo)
      delete x.discos
      return x
    }).sort(function(p, q) { return p.k < q.k ? -1 : p.k > q.k ? 1 : 0 })
    var a3 = ordenGen.map(function(k) {
      var x = gen[k]
      x.sub = contar(x.indices.length)
      x.k = sinAcentos(x.titulo)
      return x
    }).sort(function(p, q) { return q.indices.length - p.indices.length })

    canciones = lista
    porRuta = rutas
    albumes = a1
    artistas = a2
    generos = a3
    cargando = false
    actualizarLista()
  }

  Process {
    id: lector
    command: ["/usr/bin/python3", "-I", "-B", root.scriptPath, root.musicDir, root.cacheDir]
    stdout: StdioCollector { onStreamFinished: root.cargarBiblioteca(text) }
    stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") console.warn("mimusica", text.trim()) }
  }

  function recargarBiblioteca() {
    if (lector.running) return
    cargando = true
    lector.running = true
  }

  Component.onCompleted: lector.running = true

  // ---------- lista visible ----------
  function cancionesDe(indices, palabras) {
    var res = []
    for (var i = 0; i < indices.length; i++) {
      var k = canciones[indices[i]].k, ok = true
      for (var j = 0; j < palabras.length; j++) if (k.indexOf(palabras[j]) < 0) { ok = false; break }
      if (ok) res.push({ tipo: "cancion", i: indices[i] })
    }
    return res
  }

  function actualizarLista() {
    var palabras = sinAcentos(filtro.trim()).split(/\s+/).filter(function(p) { return p !== "" })
    var res
    if (grupo) {
      res = cancionesDe(grupo.indices, palabras)
    } else if (pestana === 0) {
      var todos = []
      for (var i = 0; i < canciones.length; i++) todos.push(i)
      res = cancionesDe(todos, palabras)
    } else {
      var grupos = pestana === 1 ? albumes : pestana === 2 ? artistas : generos
      res = grupos.filter(function(g) {
        for (var j = 0; j < palabras.length; j++) if (g.k.indexOf(palabras[j]) < 0) return false
        return true
      })
    }
    elementos = res
    seleccion = 0
    lista.positionViewAtBeginning()
  }

  onFiltroChanged: actualizarLista()

  function limpiarFiltro() {
    buscador.text = ""
    filtro = ""
  }

  function cambiarPestana(n) {
    pestana = (n + pestanas.length) % pestanas.length
    grupo = null
    limpiarFiltro()
    actualizarLista()
  }

  function abrirGrupo(g) {
    grupo = g
    limpiarFiltro()
    actualizarLista()
  }

  function volver() {
    grupo = null
    limpiarFiltro()
    actualizarLista()
  }

  function activar(n) {
    if (n < 0 || n >= elementos.length) return
    var e = elementos[n]
    if (e.tipo === "cancion") {
      var cola = []
      var inicio = 0
      for (var i = 0; i < elementos.length; i++) {
        if (elementos[i].tipo !== "cancion") continue
        if (i === n) inicio = cola.length
        cola.push(elementos[i].i)
      }
      reproducirCola(cola, inicio, false)
    } else {
      abrirGrupo(e)
    }
  }

  function mover(d) {
    if (elementos.length === 0) return
    seleccion = Math.max(0, Math.min(elementos.length - 1, seleccion + d))
    lista.positionViewAtIndex(seleccion, ListView.Contain)
  }

  onOpenedChanged: if (opened) { limpiarFiltro(); actualizarLista() }

  // ---------- mpv ----------
  function enviar(cmd) {
    if (sock.connected) {
      sock.write(JSON.stringify({ command: cmd }) + "\n")
      sock.flush()
      return
    }
    var p = pendientes.slice()
    p.push(cmd)
    pendientes = p
    arrancarMpv()
  }

  property bool arrancando: false
  function arrancarMpv() {
    if (arrancando) return
    arrancando = true
    Quickshell.execDetached(["sh", "-c",
      "mkdir -p \"$1\" && exec mpv --idle=yes --no-video --no-terminal --force-window=no --volume=" + Math.round(volumen) + " --input-ipc-server=\"$2\"",
      "mimusica", runDir, socketPath])
    reintento.restart()
  }

  function alConectar() {
    arrancando = false
    var obs = ["pause", "idle-active", "path", "filename/no-ext", "duration", "volume"]
    for (var i = 0; i < obs.length; i++)
      sock.write(JSON.stringify({ command: ["observe_property", i + 1, obs[i]] }) + "\n")
    var p = pendientes
    pendientes = []
    for (var j = 0; j < p.length; j++) sock.write(JSON.stringify({ command: p[j] }) + "\n")
    sock.flush()
  }

  function recibir(linea) {
    var m
    try { m = JSON.parse(linea) } catch (e) { return }
    if (m.request_id === 100) { if (typeof m.data === "number") posicion = m.data; return }
    if (m.event !== "property-change") return
    var d = m.data
    switch (m.name) {
    case "pause": pausado = !!d; break
    case "idle-active": inactivo = !!d; if (d) { posicion = 0; duracion = 0 } break
    case "path": ruta = typeof d === "string" ? d : ""; posicion = 0; break
    case "filename/no-ext": archivo = typeof d === "string" ? d.slice(0, 300) : ""; break
    case "duration": duracion = typeof d === "number" ? d : 0; break
    case "volume": if (typeof d === "number") volumen = d; break
    }
  }

  Socket {
    id: sock
    path: root.socketPath
    connected: true
    parser: SplitParser { onRead: function(linea) { root.recibir(linea) } }
    onConnectedChanged: {
      if (connected) root.alConectar()
      else { root.inactivo = true; root.ruta = ""; root.archivo = ""; root.pausado = true }
    }
  }

  // Mientras mpv arranca, reintenta la conexión unos segundos.
  Timer {
    id: reintento
    interval: 250
    repeat: true
    property int intentos: 0
    onTriggered: {
      if (sock.connected) { stop(); intentos = 0; return }
      if (++intentos > 40) { stop(); intentos = 0; root.arrancando = false; root.pendientes = []; console.warn("mimusica: mpv no respondió"); return }
      sock.connected = true
    }
  }

  // Si mpv quedó abierto de antes (p. ej. tras recargar el shell), se reengancha.
  Timer {
    interval: 5000
    repeat: true
    running: !sock.connected && !reintento.running
    onTriggered: sock.connected = true
  }

  // La posición se pide solo con el panel abierto y la música sonando.
  Timer {
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: root.opened && root.sonando && !root.pausado
    onTriggered: sock.write(JSON.stringify({ command: ["get_property", "time-pos"], request_id: 100 }) + "\n")
  }

  // ---------- acciones ----------
  // Manda a mpv la cola (índices de canciones) y empieza por `inicio`.
  function reproducirCola(indices, inicio, mezclar) {
    if (indices.length === 0) return
    var m3u = "#EXTM3U\n"
    for (var i = 0; i < indices.length; i++) m3u += canciones[indices[i]].p.replace(/[\r\n]/g, " ") + "\n"
    enviar(["loadlist", "memory://" + m3u, "replace"])
    if (mezclar) {
      aleatorio = true
      enviar(["playlist-shuffle"])
      enviar(["playlist-play-index", 0])
    } else {
      enviar(["playlist-play-index", inicio])
      if (aleatorio) enviar(["playlist-shuffle"])
    }
    enviar(["set_property", "pause", false])
  }

  function reproducirGrupo(mezclar) {
    if (!grupo) return
    reproducirCola(grupo.indices, 0, mezclar)
  }

  function playPausa() {
    if (sonando) { enviar(["cycle", "pause"]); return }
    var todos = []
    for (var i = 0; i < canciones.length; i++) todos.push(i)
    reproducirCola(todos, 0, true)   // nada cargado: toda la biblioteca en aleatorio
  }

  function siguiente() { if (sonando) enviar(["playlist-next", "force"]) }
  function anterior() {
    if (!sonando) return
    if (posicion > 5) enviar(["seek", 0, "absolute"])
    else enviar(["playlist-prev", "force"])
  }
  function cambiarAleatorio() {
    aleatorio = !aleatorio
    if (sonando) enviar([aleatorio ? "playlist-shuffle" : "playlist-unshuffle"])
  }
  function detener() { if (sock.connected) enviar(["quit"]) }

  // Ir al disco de lo que suena.
  function irAlDisco() {
    if (!cancionActual) return
    for (var i = 0; i < albumes.length; i++) {
      var a = albumes[i]
      if (a.titulo === cancionActual.al && a.artista === cancionActual.aa) {
        pestana = 1
        abrirGrupo(a)
        for (var j = 0; j < elementos.length; j++) if (elementos[j].i === actual) { seleccion = j; lista.positionViewAtIndex(j, ListView.Center); break }
        return
      }
    }
  }

  // ---------- barra ----------
  implicitWidth: fila.implicitWidth + Style.space(14)
  implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal

  Row {
    id: fila
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: root.sonando && root.pausado ? "󰐊" : "󰝚"
      color: root.sonando && !root.pausado ? root.barFg : Qt.darker(root.barFg, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      visible: root.sonando && !(root.bar && root.bar.vertical)
      width: Math.min(implicitWidth, Style.space(200))
      elide: Text.ElideRight
      text: root.titulo + (root.artista ? "  ·  " + root.artista : "")
      color: root.pausado ? Qt.darker(root.barFg, 1.5) : root.barFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.LeftButton) root.toggle()
      else if (mouse.button === Qt.MiddleButton) root.siguiente()
      else root.playPausa()
    }
    onWheel: function(wheel) {
      if (wheel.angleDelta.y > 0) root.anterior()
      else if (wheel.angleDelta.y < 0) root.siguiente()
    }
    onEntered: if (root.bar && !root.opened) root.bar.showTooltip(root, root.sonando
      ? root.titulo + (root.artista ? " — " + root.artista : "")
      : "Mi música · clic derecho: aleatorio")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // ---------- panel ----------
  KeyboardPanel {
    id: panel
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: buscador
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(columna.implicitHeight)

    Column {
      id: columna
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(10)

      // Lo que suena
      Item {
        width: parent.width
        height: Style.space(64)

        Portada {
          fondo: Style.normalFillFor(root.fg, root.acento)
          colorGlifo: root.dim
          familia: root.fontFamily
          id: portadaGrande
          width: Style.space(64)
          height: Style.space(64)
          archivo: root.cancionActual ? root.cancionActual.c : ""
        }

        Column {
          anchors.left: portadaGrande.right
          anchors.leftMargin: Style.space(12)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            text: root.sonando ? root.titulo : "Nada sonando"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            text: root.sonando ? root.artista
              : (root.cargando ? "Leyendo tu música…" : root.canciones.length + " canciones · " + root.albumes.length + " discos · " + root.artistas.length + " artistas")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            visible: !!root.cancionActual
            text: root.cancionActual ? "󰀥 " + root.cancionActual.al + (root.cancionActual.y ? " (" + root.cancionActual.y + ")" : "") : ""
            color: discoArea.containsMouse ? root.acento : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            MouseArea {
              id: discoArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.irAlDisco()
            }
          }
        }
      }

      // Progreso
      Row {
        width: parent.width
        spacing: Style.space(8)
        visible: root.sonando

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: root.tiempo(progreso.dragging ? progreso.liveValue : root.posicion)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          width: Style.space(36)
        }
        PanelSlider {
          id: progreso
          bar: root.bar
          width: parent.width - Style.space(88)
          anchors.verticalCenter: parent.verticalCenter
          minimum: 0
          maximum: Math.max(1, root.duracion)
          value: root.posicion
          onReleased: function(v) { root.posicion = v; root.enviar(["seek", v, "absolute"]) }
        }
        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: root.tiempo(root.duracion)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          width: Style.space(36)
          horizontalAlignment: Text.AlignRight
        }
      }

      // Controles y volumen
      Row {
        width: parent.width
        spacing: Style.space(4)
        LayoutMirroring.enabled: false
        LayoutMirroring.childrenInherit: true

        Button {
          iconText: "󰒝"
          tooltipText: root.aleatorio ? "Aleatorio activado" : "Aleatorio desactivado"
          foreground: root.fg
          selected: root.aleatorio
          opacity: root.aleatorio ? 1 : 0.5
          onClicked: root.cambiarAleatorio()
        }
        Button {
          iconText: "󰒮"
          foreground: root.fg
          enabled: root.sonando
          opacity: enabled ? 1 : 0.4
          onClicked: root.anterior()
        }
        Button {
          iconText: root.sonando && !root.pausado ? "󰏤" : "󰐊"
          foreground: root.fg
          iconSize: Style.font.iconLarge
          onClicked: root.playPausa()
        }
        Button {
          iconText: "󰒭"
          foreground: root.fg
          enabled: root.sonando
          opacity: enabled ? 1 : 0.4
          onClicked: root.siguiente()
        }
        Button {
          iconText: "󰓛"
          tooltipText: "Detener"
          foreground: root.fg
          enabled: root.sonando
          opacity: enabled ? 1 : 0.4
          onClicked: root.detener()
        }

        Item { width: Style.space(6); height: 1 }

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: root.volumen <= 0 ? "󰝟" : (root.volumen < 50 ? "󰖀" : "󰕾")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        PanelSlider {
          bar: root.bar
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(Style.space(60), columna.width - x)
          minimum: 0
          maximum: 100
          integer: true
          value: root.volumen
          onMoved: function(v) { root.volumen = v; if (sock.connected) root.enviar(["set_property", "volume", v]) }
        }
      }

      PanelSeparator { foreground: root.fg }

      // Pestañas
      Row {
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: root.pestanas
          Button {
            required property var modelData
            required property int index
            text: modelData
            foreground: root.fg
            selected: root.pestana === index
            opacity: selected ? 1 : 0.6
            onClicked: root.cambiarPestana(index)
          }
        }

        Item { width: 1; height: 1 }

        Button {
          iconText: "󰑐"
          tooltipText: "Volver a leer ~/Music"
          foreground: root.fg
          opacity: root.cargando ? 0.3 : 0.6
          onClicked: root.recargarBiblioteca()
        }
      }

      // Cabecera del disco / artista / género abierto
      Item {
        width: parent.width
        height: visible ? Style.space(56) : 0
        visible: root.grupo !== null

        Button {
          id: atras
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰁍"
          tooltipText: "Volver (Esc)"
          foreground: root.fg
          onClicked: root.volver()
        }

        Portada {
          fondo: Style.normalFillFor(root.fg, root.acento)
          colorGlifo: root.dim
          familia: root.fontFamily
          id: portadaGrupo
          anchors.left: atras.right
          anchors.leftMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(48)
          height: Style.space(48)
          archivo: root.grupo ? root.grupo.c : ""
          glifo: root.grupo && root.grupo.tipo === "artista" ? "󰠃" : root.grupo && root.grupo.tipo === "genero" ? "󰎈" : "󰀥"
        }

        Column {
          anchors.left: portadaGrupo.right
          anchors.leftMargin: Style.space(10)
          anchors.right: botonesGrupo.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            text: root.grupo ? root.grupo.titulo : ""
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            text: root.grupo ? root.grupo.sub : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          id: botonesGrupo
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Button {
            iconText: "󰐊"
            tooltipText: "Reproducir todo"
            foreground: root.fg
            onClicked: root.reproducirGrupo(false)
          }
          Button {
            iconText: "󰒝"
            tooltipText: "Reproducir en aleatorio"
            foreground: root.fg
            onClicked: root.reproducirGrupo(true)
          }
        }
      }

      // Buscador
      Item {
        width: parent.width
        height: Style.space(28)

        Text {
          id: lupa
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "󰍉"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        FilterInput {
          id: buscador
          anchors.left: lupa.right
          anchors.leftMargin: Style.space(8)
          anchors.right: contador.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          onTextChanged: root.filtro = text
          Keys.onPressed: function(event) {
            if (event.modifiers & (Qt.AltModifier | Qt.MetaModifier)) { event.accepted = true; return }
            var k = event.key
            if (k === Qt.Key_Escape) { if (root.grupo) root.volver(); else root.close(); event.accepted = true }
            else if (k === Qt.Key_Tab) { root.cambiarPestana(root.pestana + 1); event.accepted = true }
            else if (k === Qt.Key_Backtab) { root.cambiarPestana(root.pestana - 1); event.accepted = true }
            else if (k === Qt.Key_Backspace && buscador.text === "" && root.grupo) { root.volver(); event.accepted = true }
            else if (k === Qt.Key_Down) { root.mover(1); event.accepted = true }
            else if (k === Qt.Key_Up) { root.mover(-1); event.accepted = true }
            else if (k === Qt.Key_PageDown) { root.mover(8); event.accepted = true }
            else if (k === Qt.Key_PageUp) { root.mover(-8); event.accepted = true }
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) { root.activar(root.seleccion); event.accepted = true }
          }
        }

        Text {
          textFormat: Text.PlainText
          anchors.fill: buscador
          verticalAlignment: Text.AlignVCenter
          visible: buscador.text === "" && !buscador.preeditText
          text: root.grupo ? "Buscar en " + root.grupo.titulo + "…"
            : ["Buscar canción, artista o disco…", "Buscar disco…", "Buscar artista…", "Buscar género…"][root.pestana]
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          id: contador
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.elementos.length
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // Lista
      ListView {
        id: lista
        width: parent.width
        height: Style.space(root.grupo ? 300 : 360)
        clip: true
        model: root.elementos
        currentIndex: root.seleccion
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: Style.space(200)

        delegate: BorderSurface {
          id: filaItem
          required property var modelData
          required property int index
          readonly property bool esCancion: modelData.tipo === "cancion"
          readonly property var cancion: esCancion ? root.canciones[modelData.i] : null
          readonly property bool suena: esCancion && modelData.i === root.actual
          readonly property bool marcada: index === root.seleccion
          readonly property bool enDisco: root.grupo !== null && root.grupo.tipo === "album"

          width: lista.width
          height: Style.space(enDisco ? 36 : 46)
          radius: Style.spacing.labelGap
          color: marcada ? Style.selectedFillFor(root.fg, root.acento) : "transparent"
          borderSpec: marcada ? Border.controlSpec("normal", root.fg, root.acento) : Border.none()

          // número de pista (dentro de un disco) o carátula
          Text {
            id: pista
            visible: filaItem.enDisco
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(26)
            horizontalAlignment: Text.AlignRight
            text: filaItem.suena ? (root.pausado ? "󰏤" : "󰝚") : (filaItem.cancion && filaItem.cancion.n ? filaItem.cancion.n : "·")
            color: filaItem.suena ? root.acento : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Portada {
            fondo: Style.normalFillFor(root.fg, root.acento)
            colorGlifo: root.dim
            familia: root.fontFamily
            id: miniatura
            visible: !filaItem.enDisco
            anchors.left: parent.left
            anchors.leftMargin: Style.space(5)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(36)
            height: Style.space(36)
            archivo: filaItem.esCancion ? (filaItem.cancion ? filaItem.cancion.c : "") : (filaItem.modelData.c || "")
            glifo: filaItem.modelData.tipo === "artista" ? "󰠃" : filaItem.modelData.tipo === "genero" ? "󰎈" : "󰝚"

            Rectangle {
              anchors.fill: parent
              radius: parent.radius
              visible: filaItem.suena
              color: Qt.rgba(0, 0, 0, 0.55)
              Text {
                anchors.centerIn: parent
                text: root.pausado ? "󰏤" : "󰝚"
                color: root.acento
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          Column {
            anchors.left: filaItem.enDisco ? pista.right : miniatura.right
            anchors.leftMargin: Style.space(10)
            anchors.right: flecha.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideRight
              text: filaItem.esCancion ? filaItem.cancion.t : filaItem.modelData.titulo
              color: filaItem.suena ? root.acento : root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: filaItem.suena || !filaItem.esCancion
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideRight
              visible: text !== ""
              text: {
                if (!filaItem.esCancion) return filaItem.modelData.sub
                var c = filaItem.cancion
                if (filaItem.enDisco) return c.a !== c.aa ? c.a : ""
                if (root.grupo && root.grupo.tipo === "artista") return c.al + (c.y ? " · " + c.y : "")
                return c.a + " · " + c.al
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            id: flecha
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: filaItem.esCancion ? "" : "󰅂"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: root.seleccion = filaItem.index
            onClicked: root.activar(filaItem.index)
          }
        }
      }
    }
  }
}
