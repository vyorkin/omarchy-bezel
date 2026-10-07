import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The 8.8" case panel from the bar: which theme it shows, and the handful of
// parameters worth touching without opening Bezel Studio.
//
// Nothing about themes lives here. Every read and write goes through
// `bin/omarchy-bezel`, which reads the same theme folders bezel reads, edits a
// theme's `theme.json` in place (keeping one `.bak`), and hands the screen to
// the chosen theme through the `bezel-run@<theme>` systemd user unit. The
// widget is therefore stateless: opening it re-reads the disk, so the studio,
// a terminal and this popup can never disagree for long.
//
// Actions: left click opens the popup, middle click takes the panel off the
// screen or puts it back, Escape closes, the arrow keys walk the lists, Enter
// acts, and edits are debounced so a slider drag restarts the theme once.
Panel {
  id: root

  moduleName: "io.github.vyorkin.omarchy-bezel"
  ipcTarget: "io.github.vyorkin.omarchy-bezel"

  // ------------------------------------------------------------- model state

  property var themes: []
  property string current: ""
  property string themesDir: ""
  property string unitState: "absent"
  property int brightness: 67
  property real refreshSeconds: 1.0
  property string orientation: "portrait"
  property string backgroundType: "color"
  property var elements: []
  property var backgroundColors: []
  property var palette: []
  property bool busy: false
  property string errorText: ""
  // Preview freshness, by theme name: the file's mtime. Bumping it makes Qt
  // load the freshly rendered PNG instead of its cached copy.
  property var thumbMtime: ({})
  property bool thumbsPrimed: false
  property bool paletteLoaded: false

  // ------------------------------------------------------------- ui state

  // "themes" picks the theme, "elements" lists what the theme draws, "detail"
  // edits one element. One cursor per mode so going back restores the row.
  property string mode: "themes"
  property int themeCursor: 0
  property int elementCursor: 0
  property int detailCursor: 0
  property int paletteCursor: 0
  // Path inside the element of the colour a palette click paints.
  property string colorPath: ""

  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string cli: root.pluginDir + "/bin/omarchy-bezel"

  readonly property color textColor: Color.popups.text
  readonly property color foreground: bar && bar.barForeground !== undefined
    ? bar.barForeground : Color.foreground
  readonly property color dimText: Qt.darker(textColor, 1.5)
  readonly property color accent: Color.accent
  readonly property bool live: unitState === "active"
  readonly property var selectedTheme: themes.length > 0
    ? themes[Math.max(0, Math.min(themes.length - 1, themeCursor))] : null
  readonly property var openElement: elements.length > 0 && detailIndex >= 0
    ? elements[Math.max(0, Math.min(elements.length - 1, detailIndex))] : null
  property int detailIndex: -1

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: root.refresh()
  onOpenedChanged: if (root.opened) root.refresh()

  // ------------------------------------------------------------------ backend

  // Status is read on demand, never polled: the theme only changes when this
  // popup, the studio or a terminal changes it, and each of those leaves the
  // disk up to date. A quarter of a second per read is the price of never
  // showing a stale theme.
  Process {
    id: statusProcess
    command: [root.cli, "status"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.readStatus(text)
    }
  }

  // The theme whose parameters are wanted. Set before `running`, so a switch
  // from one theme to another reads the new one rather than the old.
  property string paramsTheme: ""

  Process {
    id: paramsProcess
    command: [root.cli, "params", root.paramsTheme]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.readParams(text)
        if (root.paramsQueued !== "" && root.paramsQueued !== root.current) {
          var next = root.paramsQueued
          root.paramsQueued = ""
          root.loadParams(next)
        }
      }
    }
  }

  Process {
    id: paletteProcess
    command: [root.cli, "palette"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.palette = JSON.parse(text) } catch (error) { root.palette = [] }
        root.paletteLoaded = true
      }
    }
  }

  // Previews are rendered once per changed theme and cached on disk, so this
  // costs a second on the first open and nothing afterwards.
  Process {
    id: thumbsProcess
    command: [root.cli, "thumbs"]
    running: false
    stdout: SplitParser {
      onRead: function(line) {
        try {
          var done = JSON.parse(line)
          if (done.ok) root.bumpThumb(done.theme, done.mtime)
        } catch (error) {
        }
      }
    }
    onExited: root.thumbsPrimed = true
  }

  // One fresh Process per command: a reused object can miss its exit event and
  // then keep reporting "running", which would wedge every later action.
  Component {
    id: commandComponent
    Process {
      property var onDone
      stderr: StdioCollector { id: commandError; waitForEnd: true }
      stdout: StdioCollector { id: commandOutput; waitForEnd: true }
      onExited: function(code) {
        root.busy = false
        root.errorText = code === 0 ? "" : String(commandError.text || "").trim()
        if (onDone) onDone(code, String(commandOutput.text || ""))
        destroy()
      }
    }
  }

  function run(args, onDone) {
    var process = commandComponent.createObject(root, { command: args, onDone: onDone })
    if (!process) return
    root.busy = true
    process.running = true
  }

  function refresh() {
    if (statusProcess.running) return
    statusProcess.running = true
    if (!paletteLoaded && !paletteProcess.running) paletteProcess.running = true
    if (!thumbsPrimed && !thumbsProcess.running) thumbsProcess.running = true
  }

  function readStatus(text) {
    try {
      var state = JSON.parse(text)
      root.themes = state.themes || []
      root.themesDir = state.themesDir || ""
      root.current = state.theme || ""
      root.unitState = state.state || "absent"
      root.brightness = Number(state.brightness)
      // Previews already on disk show without waiting for the render pass.
      var stamps = Object.assign({}, root.thumbMtime)
      for (var i = 0; i < root.themes.length; i++) {
        var row = root.themes[i]
        if (row.thumbMtime && (!stamps[row.name] || stamps[row.name] < row.thumbMtime))
          stamps[row.name] = row.thumbMtime
      }
      root.thumbMtime = stamps
      var index = root.indexOfTheme(root.current)
      if (index >= 0 && root.mode === "themes") root.themeCursor = index
      root.loadParams(root.current)
    } catch (error) {
      root.errorText = "cannot read the panels"
    }
  }

  function readParams(text) {
    try {
      var params = JSON.parse(text)
      root.refreshSeconds = Number(params.refreshSeconds)
      root.orientation = params.orientation || "portrait"
      root.backgroundType = params.backgroundType || "color"
      root.backgroundColors = params.backgroundColors || []
      root.elements = params.elements || []
      if (!root.colorPath && root.backgroundColors.length > 0)
        root.colorPath = root.backgroundColors[0].path
    } catch (error) {
      root.errorText = "cannot read the theme"
    }
  }

  function loadParams(name) {
    if (!name) return
    root.paramsTheme = name
    if (paramsProcess.running) {
      // A read is already on the wire; remember the newer name and re-read when
      // it lands, so the panel never shows one theme's parameters under another.
      root.paramsQueued = name
      return
    }
    paramsProcess.running = true
  }

  property string paramsQueued: ""

  function indexOfTheme(name) {
    for (var i = 0; i < root.themes.length; i++)
      if (root.themes[i].name === name) return i
    return -1
  }

  function bumpThumb(name, mtime) {
    var next = root.thumbMtime
    next[name] = mtime
    root.thumbMtime = next
  }

  function thumbSource(name) {
    if (!name) return ""
    var theme = root.themes[root.indexOfTheme(name)]
    if (!theme || !theme.thumb) return ""
    var stamp = root.thumbMtime[name] || 0
    if (stamp === 0) return ""
    return "file://" + theme.thumb + "?m=" + stamp
  }

  // Index of `value` in the palette presets, or -1: lets the strip mark the
  // preset a colour currently came from.
  function paletteIndexFor(value) {
    for (var i = 0; i < root.palette.length; i++)
      if (root.palette[i].value === value) return i
    return -1
  }

  // The colour a dotted path currently holds, wherever it lives.
  function colorValueOf(path) {
    if (!path) return ""
    var i
    for (i = 0; i < root.backgroundColors.length; i++)
      if (root.backgroundColors[i].path === path) return root.backgroundColors[i].value
    for (i = 0; i < root.elements.length; i++) {
      var element = root.elements[i]
      for (var j = 0; j < element.colors.length; j++) {
        var full = "elements." + element.index + "." + element.colors[j].path
        if (full === path) return element.colors[j].value
      }
    }
    return ""
  }

  // --------------------------------------------------------------- commands

  function useTheme(name) {
    if (!name) return
    root.current = name
    root.run([root.cli, "use", name], function() { root.refresh() })
  }

  function togglePanel() {
    if (root.live) root.run([root.cli, "stop"], function() { root.refresh() })
    else root.useTheme(root.current)
  }

  // Edits go through one queue: a slider drag and the click that follows it
  // collapse into a single write and a single restart of the theme.
  property var pendingSpecs: []

  function edit(spec) {
    var specs = root.pendingSpecs.slice()
    for (var i = 0; i < specs.length; i++) {
      if (specs[i].split("=")[0] === spec.split("=")[0]) {
        specs[i] = spec
        root.pendingSpecs = specs
        applyTimer.restart()
        return
      }
    }
    specs.push(spec)
    root.pendingSpecs = specs
    applyTimer.restart()
  }

  Timer {
    id: applyTimer
    interval: 250
    repeat: false
    onTriggered: root.flushEdits()
  }

  function flushEdits() {
    if (root.pendingSpecs.length === 0 || !root.current) return
    var specs = root.pendingSpecs
    root.pendingSpecs = []
    root.run([root.cli, "set", root.current].concat(specs), function(code, output) {
      if (code !== 0) return
      try {
        var result = JSON.parse(output)
        if (result.thumb && result.thumb.ok)
          root.bumpThumb(result.thumb.theme, result.thumb.mtime)
      } catch (error) {
      }
      root.refresh()
    })
  }

  function setBrightness(percent) {
    percent = Math.max(0, Math.min(100, Math.round(percent)))
    root.brightness = percent
    root.edit("brightness=" + percent)
  }

  function setRefresh(seconds) {
    root.refreshSeconds = Math.max(0.25, Math.min(10, Math.round(seconds * 20) / 20))
    root.edit("refresh=" + root.refreshSeconds)
  }

  function setFlip(flipped) {
    var base = root.orientation.indexOf("landscape") === 0 ? "landscape" : "portrait"
    root.orientation = flipped
      ? (base === "landscape" ? "reverse-landscape" : "reverse-portrait")
      : base
    root.edit("orientation=" + root.orientation)
  }

  function setElementVisible(element, visible) {
    if (!element) return
    element.visible = visible
    root.elements = root.elements.slice()
    root.edit("elements." + element.index + ".visible=" + visible)
  }

  function setElementOpacity(element, value) {
    if (!element) return
    element.opacity = Math.max(0, Math.min(1, Math.round(value * 100) / 100))
    root.elements = root.elements.slice()
    root.edit("elements." + element.index + ".opacity=" + element.opacity)
  }

  function setElementSize(element, value) {
    if (!element) return
    element.size = Math.max(6, Math.min(240, Math.round(value)))
    root.elements = root.elements.slice()
    root.edit("elements." + element.index + ".kind.style.size=" + element.size)
  }

  function paint(path, value) {
    if (!path) return
    root.edit(path + "=" + value)
    if (root.openElement && path.indexOf("elements.") === 0) {
      var colors = root.openElement.colors
      for (var i = 0; i < colors.length; i++)
        if ("elements." + root.openElement.index + "." + colors[i].path === path)
          colors[i].value = value
      root.elements = root.elements.slice()
    }
  }

  // -------------------------------------------------------------------- glyph

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    foreground: root.foreground
    tooltipText: root.current === ""
      ? "Case panel"
      : "Case panel · " + root.current + (root.live ? "" : " (off)")

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.togglePanel()
      else root.toggle()
    }

    // A tall screen drawn as an outline, with the backlight level filled in
    // from the bottom: the glyph says what the panel is doing without a second
    // icon or a colour change.
    iconComponent: Component {
      Canvas {
        id: glyph
        antialiasing: true

        onPaint: {
          var ctx = getContext("2d")
          var size = Math.min(width, height)
          var line = Math.max(1, size * 0.09)
          var bodyWidth = size * 0.52
          var bodyHeight = size * 0.78
          var x = (width - bodyWidth) / 2
          var y = (height - bodyHeight) / 2
          var radius = bodyWidth * 0.18
          ctx.reset()
          ctx.globalAlpha = root.live ? 1.0 : 0.45
          ctx.strokeStyle = root.foreground
          ctx.lineWidth = line
          rounded(ctx, x, y, bodyWidth, bodyHeight, radius)
          ctx.stroke()
          var fill = Math.max(0, Math.min(1, root.brightness / 100))
          var inner = bodyHeight - line * 2
          if (fill > 0.01 && root.live) {
            ctx.fillStyle = root.foreground
            rounded(ctx, x + line / 2, y + line / 2 + inner * (1 - fill),
                    bodyWidth - line, inner * fill, radius * 0.6)
            ctx.fill()
          }
          ctx.globalAlpha = 1.0
        }

        // The Canvas 2D subset Qt implements has no `roundRect`; this is the
        // same shape built from lines and quadratics.
        function rounded(ctx, x, y, w, h, r) {
          r = Math.min(r, w / 2, h / 2)
          ctx.beginPath()
          ctx.moveTo(x + r, y)
          ctx.lineTo(x + w - r, y)
          ctx.quadraticCurveTo(x + w, y, x + w, y + r)
          ctx.lineTo(x + w, y + h - r)
          ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h)
          ctx.lineTo(x + r, y + h)
          ctx.quadraticCurveTo(x, y + h, x, y + h - r)
          ctx.lineTo(x, y + r)
          ctx.quadraticCurveTo(x, y, x + r, y)
          ctx.closePath()
        }

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections {
          target: root
          function onBrightnessChanged() { glyph.requestPaint() }
          function onForegroundChanged() { glyph.requestPaint() }
          function onUnitStateChanged() { glyph.requestPaint() }
        }
      }
    }
  }

  // -------------------------------------------------------------------- popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // The body's sections all have fixed heights, so this number is the same on
    // the first frame as after the themes and the parameters have been read.
    contentHeight: panel.fittedContentHeight(Style.space(740), Style.space(800))

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activate()
      onCloseRequested: {
        if (root.mode === "detail") root.mode = "elements"
        else if (root.mode === "elements") root.mode = "themes"
        else root.close()
      }

      Column {
        id: body
        width: parent.width
        spacing: Style.spacing.controlGap

        // ------------------------------------------------------------- header

        RowLayout {
          width: parent.width
          height: Style.space(24)
          spacing: Style.spacing.controlGap

          PanelSectionHeader {
            text: "Case panel"
            foreground: root.textColor
          }

          Item { Layout.fillWidth: true }

          Text {
            text: root.current + (root.unitState === "masked" ? " · masked" : "")
            color: root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
          }

          ToggleSwitch {
            checked: root.live
            busy: root.busy
            foreground: root.textColor
            onToggled: root.togglePanel()
          }
        }

        PanelSeparator { foreground: root.textColor }

        // ------------------------------------------------- theme list + preview

        RowLayout {
          width: parent.width
          spacing: Style.spacing.controlGap

          Rectangle {
            Layout.alignment: Qt.AlignTop
            Layout.preferredWidth: Style.space(46)
            Layout.preferredHeight: Style.space(150)
            color: Color.popups.background
            border.width: Math.max(1, Style.normalBorderWidth)
            border.color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.25)
            radius: Math.round(Style.cornerRadius * 0.5)

            Image {
              anchors.fill: parent
              anchors.margins: Style.space(2)
              source: root.thumbSource(root.selectedTheme ? root.selectedTheme.name : "")
              sourceSize.width: Style.space(46)
              sourceSize.height: Style.space(150)
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              cache: false
            }
          }

          ListView {
            id: themeList
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(150)
            // `height` is explicit, so the implicit height must not follow the
            // content: the popup measures the column once, and a list that grew
            // afterwards would draw past the panel's edge.
            implicitHeight: height
            clip: true
            spacing: Style.space(2)
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            model: root.themes
            currentIndex: root.mode === "themes" ? root.themeCursor : -1
            onCurrentIndexChanged: if (currentIndex >= 0)
              positionViewAtIndex(currentIndex, ListView.Contain)

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            // A theme folder with nothing in it is the one case worth a
            // sentence; as a footer it costs no height of its own.
            footer: Text {
              width: themeList.width
              visible: root.themes.length === 0
              text: "No themes in " + (root.themesDir || "the Bezel themes folder")
                + ". Make or import one in Bezel Studio first."
              color: root.dimText
              wrapMode: Text.WordWrap
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            delegate: Rectangle {
              required property var modelData
              required property int index
              width: ListView.view.width
              height: Style.space(24)
              radius: Math.round(Style.cornerRadius * 0.5)
              color: (root.mode === "themes" && index === root.themeCursor)
                ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                : (hover.hovered ? Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.08)
                                 : "transparent")

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                elide: Text.ElideRight
                text: modelData.name
                color: modelData.current ? root.accent : root.textColor
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
              }

              MouseArea {
                id: hover
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                onClicked: {
                  root.mode = "themes"
                  root.themeCursor = index
                  root.useTheme(modelData.name)
                }
              }
            }
          }
        }

        // ------------------------------------------------------------ screen

        PanelSeparator { foreground: root.textColor }

        PanelSectionHeader { text: "Screen"; foreground: root.textColor }

        RowLayout {
          width: parent.width
          spacing: Style.spacing.controlGap

          Text {
            Layout.fillWidth: true
            text: "Backlight"
            color: root.textColor
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
          }

          Text {
            text: root.brightness + "%"
            color: root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
          }
        }

        PanelSlider {
          id: brightnessSlider
          bar: root.bar
          width: parent.width
          minimum: 0
          maximum: 100
          step: 1
          integer: true
          value: root.brightness
          onMoved: function(value) { root.setBrightness(value) }
          onReleased: function(value) { root.setBrightness(value) }
        }

        RowLayout {
          width: parent.width
          spacing: Style.spacing.controlGap

          Text {
            Layout.fillWidth: true
            text: "Refresh"
            color: root.textColor
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
          }

          Text {
            text: root.refreshSeconds.toFixed(2) + " s"
            color: root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
          }
        }

        PanelSlider {
          id: refreshSlider
          bar: root.bar
          width: parent.width
          minimum: 0.25
          maximum: 5
          step: 0.05
          value: root.refreshSeconds
          onMoved: function(value) { root.setRefresh(value) }
          onReleased: function(value) { root.setRefresh(value) }
        }

        RowLayout {
          width: parent.width
          spacing: Style.spacing.controlGap

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Text {
              text: "Flip"
              color: root.textColor
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            Text {
              text: root.orientation
              color: root.dimText
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
            }
          }

          ToggleSwitch {
            checked: root.orientation.indexOf("reverse") === 0
            busy: root.busy
            foreground: root.textColor
            onToggled: root.setFlip(!checked)
          }
        }

        // The backdrop is a colour in most themes and a picture or video in the
        // rest; the row stays whatever it is, so the popup keeps one height.
        RowLayout {
          width: parent.width
          spacing: Style.spacing.controlGap

          Text {
            Layout.fillWidth: true
            text: "Backdrop"
            color: root.backgroundColors.length > 0 ? root.textColor : root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
          }

          Text {
            visible: root.backgroundColors.length === 0
            text: "picture or video"
            color: root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
          }

          PaletteStrip {
            visible: root.backgroundColors.length > 0
            colors: root.palette
            selectedIndex: root.backgroundColors.length > 0
              ? root.paletteIndexFor(root.backgroundColors[0].value) : -1
            onPicked: function(value) {
              if (root.backgroundColors.length > 0)
                root.paint(root.backgroundColors[0].path, value)
            }
          }
        }

        // ---------------------------------------------------------- elements

        PanelSeparator { foreground: root.textColor }

        RowLayout {
          width: parent.width
          spacing: Style.spacing.controlGap

          PanelSectionHeader {
            text: root.mode === "detail" && root.openElement
              ? "Element · " + root.openElement.name
              : "Elements"
            foreground: root.textColor
          }

          Item { Layout.fillWidth: true }

          PanelActionButton {
            visible: root.mode === "detail"
            iconText: "\u2190"
            tooltipText: "Back to the elements"
            foreground: root.textColor
            onClicked: root.mode = "elements"
          }
        }

        // The element list: one row per thing the theme draws. The widget knows
        // nothing about widget types, only that an element has a name, a
        // visibility and, when it has colours, paths to them.
        ListView {
          id: elementList
          width: parent.width
          height: Style.space(200)
          implicitHeight: height
          visible: root.mode !== "detail" && root.elements.length > 0
          clip: true
          spacing: Style.space(2)
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          model: root.elements
          currentIndex: root.mode === "elements" ? root.elementCursor : -1
          onCurrentIndexChanged: if (currentIndex >= 0)
            positionViewAtIndex(currentIndex, ListView.Contain)

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: Rectangle {
            required property var modelData
            required property int index
            width: ListView.view.width
            height: Style.space(26)
            radius: Math.round(Style.cornerRadius * 0.5)
            color: (root.mode === "elements" && index === root.elementCursor)
              ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
              : (rowHover.hovered ? Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.08)
                                  : "transparent")

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.spacing.controlGap

              Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: modelData.name
                color: modelData.visible ? root.textColor : root.dimText
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
              }

              Text {
                text: modelData.type
                color: root.dimText
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                textFormat: Text.PlainText
              }

              ToggleSwitch {
                trackHeight: Style.space(14)
                checked: modelData.visible
                foreground: root.textColor
                onToggled: root.setElementVisible(modelData, !modelData.visible)
              }
            }

            MouseArea {
              id: rowHover
              anchors.fill: parent
              anchors.rightMargin: Style.space(44)
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton
              onClicked: {
                root.mode = "detail"
                root.detailIndex = index
                root.elementCursor = index
                root.detailCursor = 0
                root.colorPath = modelData.colors.length > 0
                  ? "elements." + modelData.index + "." + modelData.colors[0].path
                  : root.colorPath
              }
            }
          }
        }

        Text {
          width: parent.width
          height: Style.space(200)
          visible: root.mode !== "detail" && root.elements.length === 0
          text: root.current === ""
            ? "No theme to read."
            : "This theme draws nothing of its own — it is just a background."
          color: root.dimText
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
        }

        // The element's own parameters: visibility, opacity, type size and every
        // colour it draws with, gradient stops included. The viewport is exactly
        // as tall as the element list above, so the popup keeps one size in
        // every mode and in every load; dense themes scroll inside it.
        Flickable {
          id: detail
          visible: root.mode === "detail" && root.openElement !== null
          width: parent.width
          height: Style.space(200)
          contentHeight: detailColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: detailColumn
            width: detail.width
            spacing: Style.spacing.controlGap

          RowLayout {
            width: parent.width
            spacing: Style.spacing.controlGap

            Text {
              Layout.fillWidth: true
              text: "Visible"
              color: root.textColor
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            ToggleSwitch {
              checked: root.openElement ? root.openElement.visible : false
              foreground: root.textColor
              onToggled: if (root.openElement)
                root.setElementVisible(root.openElement, !root.openElement.visible)
            }
          }

          DetailSlider {
            label: "Opacity"
            valueText: root.openElement ? Math.round(root.openElement.opacity * 100) + "%" : ""
            from: 0
            to: 1
            step: 0.05
            value: root.openElement ? root.openElement.opacity : 1
            active: root.openElement !== null && root.detailCursor === 1
            onPicked: function(value) { root.setElementOpacity(root.openElement, value) }
            onMoving: function(value) { root.setElementOpacity(root.openElement, value) }
          }

          DetailSlider {
            visible: root.openElement !== null && root.openElement.type === "text"
            label: "Size"
            valueText: root.openElement && root.openElement.size !== null
              ? Math.round(root.openElement.size) + " px" : ""
            from: 6
            to: 240
            step: 1
            value: root.openElement && root.openElement.size !== null ? root.openElement.size : 16
            active: root.openElement !== null && root.detailCursor === 2
            onPicked: function(value) { root.setElementSize(root.openElement, value) }
            onMoving: function(value) { root.setElementSize(root.openElement, value) }
          }

          PanelSectionHeader {
            visible: root.openElement !== null && root.openElement.colors.length > 0
            text: "Colours"
            foreground: root.textColor
          }

          Repeater {
            model: root.openElement ? root.openElement.colors : []

            delegate: Rectangle {
              required property var modelData
              required property int index
              readonly property string fullPath: root.openElement
                ? "elements." + root.openElement.index + "." + modelData.path : ""
              width: detail.width
              height: Style.space(22)
              radius: Math.round(Style.cornerRadius * 0.5)
              color: root.openElement && root.detailCursor === 3 + index
                ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                : (colourHover.hovered ? Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.08)
                                       : "transparent")

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.spacing.controlGap

                Rectangle {
                  Layout.preferredWidth: Style.space(14)
                  Layout.preferredHeight: Style.space(14)
                  radius: Math.max(1, Math.round(Style.cornerRadius * 0.4))
                  color: modelData.value
                  border.width: root.colorPath === fullPath
                    ? Math.max(1, Style.normalBorderWidth) : 0
                  border.color: root.accent
                }

                Text {
                  Layout.fillWidth: true
                  elide: Text.ElideMiddle
                  text: modelData.path.replace(/^kind\./, "")
                  color: root.textColor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                }

                Text {
                  text: modelData.value
                  color: root.dimText
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                }
              }

              MouseArea {
                id: colourHover
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                onClicked: {
                  root.detailCursor = 3 + index
                  root.colorPath = fullPath
                  var preset = root.paletteIndexFor(modelData.value)
                  if (preset >= 0) root.paletteCursor = preset
                }
              }
            }
          }

          RowLayout {
            width: parent.width
            visible: root.openElement !== null && root.openElement.colors.length > 0
            spacing: Style.spacing.controlGap

            Text {
              Layout.fillWidth: true
              text: "Paint with"
              color: root.textColor
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            PaletteStrip {
              colors: root.palette
              selectedIndex: root.paletteIndexFor(root.colorValueOf(root.colorPath))
              onPicked: function(value, index) {
                root.paletteCursor = index
                root.paint(root.colorPath, value)
              }
            }
          }

          Text {
            width: parent.width
            visible: root.openElement !== null && root.openElement.colors.length === 0
            text: root.openElement && root.openElement.type === "image"
              ? "A picture: it has no colour of its own, only opacity."
              : "No colours in this element."
            color: root.dimText
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
          }
          }
        }

        Text {
          width: parent.width
          // Two lines, always there: an error appears without moving anything.
          height: Style.space(26)
          opacity: root.errorText !== "" ? 1 : 0
          text: root.errorText
          color: Color.urgent
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
        }

        Text {
          width: parent.width
          height: Style.space(26)
          text: root.mode === "detail"
            ? "Changes are written to the theme's theme.json and the screen follows."
            : "Enter picks a theme, arrows walk the lists, middle click takes the panel off."
          color: root.dimText
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
        }
      }
    }
  }

  // ------------------------------------------------------------------ keyboard

  function moveCursor(dx, dy) {
    if (root.mode === "themes") {
      if (dx > 0 && root.elements.length > 0) { root.mode = "elements"; return }
      if (dy !== 0 && root.themes.length > 0)
        root.themeCursor = Math.max(0, Math.min(root.themes.length - 1, root.themeCursor + dy))
      return
    }
    if (root.mode === "elements") {
      if (dx < 0) { root.mode = "themes"; return }
      if (dx > 0 && root.elements.length > 0) { root.openDetail(root.elementCursor); return }
      if (dy !== 0 && root.elements.length > 0)
        root.elementCursor = Math.max(0, Math.min(root.elements.length - 1, root.elementCursor + dy))
      return
    }
    // detail
    if (dx < 0) { root.mode = "elements"; return }
    var rows = root.detailRows()
    if (dy !== 0)
      root.detailCursor = Math.max(0, Math.min(rows - 1, root.detailCursor + dy))
    if (dx > 0 && root.openElement && root.openElement.colors.length > 0) {
      var last = rows - 1
      if (root.detailCursor === last)
        root.detailCursor = 3 + Math.min(root.openElement.colors.length - 1,
          Math.max(0, root.detailCursor - 3))
    }
  }

  function detailRows() {
    if (!root.openElement) return 4
    // visible, opacity, size (text only), one row per colour, the palette row.
    var rows = 3 + (root.openElement.type === "text" ? 1 : 0) + root.openElement.colors.length
    if (root.openElement.colors.length > 0) rows += 1
    return rows
  }

  function openDetail(index) {
    if (index < 0 || index >= root.elements.length) return
    root.mode = "detail"
    root.detailIndex = index
    root.detailCursor = 0
    var element = root.elements[index]
    if (element.colors.length > 0) {
      root.colorPath = "elements." + element.index + "." + element.colors[0].path
      var preset = root.paletteIndexFor(element.colors[0].value)
      root.paletteCursor = preset >= 0 ? preset : 0
    }
  }

  function activate() {
    if (root.mode === "themes") {
      if (root.selectedTheme) root.useTheme(root.selectedTheme.name)
      return
    }
    if (root.mode === "elements") {
      root.openDetail(root.elementCursor)
      return
    }
    if (!root.openElement) return
    var sizeRow = root.openElement.type === "text" ? 2 : -1
    if (root.detailCursor === 0) {
      root.setElementVisible(root.openElement, !root.openElement.visible)
    } else if (root.detailCursor === 1) {
      root.setElementOpacity(root.openElement, root.openElement.opacity > 0.5 ? 0 : 1)
    } else if (root.detailCursor === sizeRow) {
      var preset = root.openElement.size > 40 ? 14 : root.openElement.size * 2
      root.setElementSize(root.openElement, preset)
    } else if (root.detailCursor >= 3
               && root.detailCursor < 3 + root.openElement.colors.length) {
      var colour = root.openElement.colors[root.detailCursor - 3]
      root.colorPath = "elements." + root.openElement.index + "." + colour.path
    } else if (root.palette.length > 0 && root.colorPath) {
      root.paint(root.colorPath, root.palette[root.paletteCursor].value)
    }
  }

  // ------------------------------------------------------------------ pieces

  // A labelled slider: the same control twice per element, with the value shown
  // while it is being dragged and after it is written.
  component DetailSlider: Column {
    id: slider_holder
    property string label: ""
    property string valueText: ""
    property real from: 0
    property real to: 1
    property real step: 0.05
    property real value: 0
    property bool active: false
    signal picked(real value)
    signal moving(real value)

    width: parent ? parent.width : 0
    spacing: Style.space(2)

    RowLayout {
      width: parent.width
      spacing: Style.spacing.controlGap

      Text {
        Layout.fillWidth: true
        text: slider_holder.label
        color: slider_holder.active ? root.accent : root.textColor
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        textFormat: Text.PlainText
      }

      Text {
        text: slider_holder.valueText
        color: root.dimText
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        textFormat: Text.PlainText
      }
    }

    PanelSlider {
      width: parent.width
      bar: root.bar
      minimum: slider_holder.from
      maximum: slider_holder.to
      step: slider_holder.step
      value: slider_holder.value
      onMoved: function(value) { slider_holder.moving(value) }
      onReleased: function(value) { slider_holder.picked(value) }
    }
  }

  // The current Omarchy palette as clickable squares: the shortest path from
  // "this colour is wrong" to "this colour is the theme's accent". The size is
  // worked out here (a positioner's own implicit size is only known once its
  // children exist, which is too late to measure a popup).
  component PaletteStrip: Item {
    id: strip
    property var colors: []
    property int selectedIndex: -1
    signal picked(string value, int index)

    readonly property int cell: Style.space(14)
    readonly property int columns: Math.max(1, Math.min(10, strip.colors.length))
    readonly property int rows: Math.ceil(strip.colors.length / strip.columns)
    Layout.preferredWidth: width
    Layout.preferredHeight: height
    width: strip.columns * strip.cell + (strip.columns - 1) * Style.space(3)
    height: strip.rows <= 0 ? 0
      : strip.rows * strip.cell + (strip.rows - 1) * Style.space(3)

    Grid {
      anchors.top: parent.top
      anchors.left: parent.left
      columns: strip.columns
      columnSpacing: Style.space(3)
      rowSpacing: Style.space(3)

      Repeater {
        model: strip.colors

        delegate: Rectangle {
          required property var modelData
          required property int index
          width: strip.cell
          height: strip.cell
          radius: Math.max(1, Math.round(Style.cornerRadius * 0.4))
          color: modelData.value
          border.width: (strip.selectedIndex === index || paletteHover.hovered)
            ? Math.max(1, Style.normalBorderWidth) : 0
          border.color: strip.selectedIndex === index ? root.accent : root.dimText

          MouseArea {
            id: paletteHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            onClicked: strip.picked(modelData.value, index)
          }
        }
      }
    }
  }
}
