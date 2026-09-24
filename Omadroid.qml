import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.dedeanth.omadroid"
  ipcTarget: "omadroid"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string backend: localPath("omadroid.sh")
  readonly property string rootBackend: localPath("omadroid-root.sh")
  readonly property string scriptDir: expandHome(String(setting("waydroidScriptDir", "~/.local/share/waydroid_script")))
  readonly property string readmePath: expandHome(String(setting("readmePath", "")))

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string androidGlyph: "󰀲"

  // Last answer of `omadroid.sh status`; see that script for the fields.
  property var st: ({})
  property var apps: []
  property var props: ({ width: "", height: "", multiWindows: false, fakeTouch: [] })
  property real cpuPercent: 0
  property var lastCpuSample: null
  // null until checked: the network test needs pkexec, so it only runs on request.
  property var net: null
  property string actionStatus: ""
  property bool busy: false
  property bool needsRestart: false

  readonly property bool running: root.st.session === "RUNNING"
  readonly property bool booted: running && root.st.booted === true
  readonly property bool healthy: root.st.binder !== false && root.st.ufwRules !== false && root.st.houdini !== false
    && !(net && net.reachable && !(net.network && net.dns))
  readonly property string stateText: !running ? "Stopped"
    : !booted ? "Starting…"
    : "Running" + (root.st.ip ? " · " + root.st.ip : "")
  readonly property var runningApps: {
    var names = {}
    for (var i = 0; i < apps.length; i++) names[apps[i].pkg] = apps[i].name
    var out = []
    var list = root.st.apps || []
    for (var j = 0; j < list.length; j++)
      if (names[list[j].pkg] !== undefined && list[j].pkg !== "com.android.vending")
        out.push({ name: names[list[j].pkg], pkg: list[j].pkg, rssKb: list[j].rssKb })
    return out
  }

  function localPath(name) {
    return decodeURIComponent(String(Qt.resolvedUrl(name)).replace(/^file:\/\//, ""))
  }

  function expandHome(path) {
    return path.indexOf("~/") === 0 ? home + path.substring(1) : path
  }

  function formatBytes(bytes) {
    var gib = bytes / 1073741824
    return gib >= 1 ? gib.toFixed(1) + " GB" : Math.round(bytes / 1048576) + " MB"
  }

  function say(text) {
    actionStatus = text
    statusClear.restart()
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function refreshAll() {
    refresh()
    if (!appsProc.running) appsProc.running = true
    if (booted && !propsProc.running) propsProc.running = true
  }

  // Session commands run one at a time; the status poll picks up the result.
  function run(args, message) {
    if (actionProc.running) return
    busy = true
    if (message) say(message)
    actionProc.command = [backend].concat(args)
    actionProc.running = true
  }

  function runRoot(args, message) {
    if (rootProc.running) return
    busy = true
    if (message) say(message)
    rootProc.mode = args[0]
    rootProc.command = ["pkexec", rootBackend].concat(args)
    rootProc.running = true
  }

  function setResolution(width, height) {
    if (!booted) return
    run(["setprop", "persist.waydroid.width", width], "")
    // setprop calls queue behind each other, so the height waits for the width to land.
    pendingProps = [["persist.waydroid.height", height]]
    props = { width: width, height: height, multiWindows: props.multiWindows, fakeTouch: props.fakeTouch || [] }
    needsRestart = true
  }

  function setMultiWindows(on) {
    if (!booted) return
    run(["setprop", "persist.waydroid.multi_windows", on ? "true" : "false"], "")
    props = { width: props.width, height: props.height, multiWindows: on, fakeTouch: props.fakeTouch || [] }
    needsRestart = true
  }

  function touchOn(pkg) {
    return (props.fakeTouch || []).indexOf(pkg) >= 0
  }

  // Waydroid hands the mouse to Android as a mouse; games that only read touch
  // ignore some clicks (Saint Seiya's target picking). fake_touch turns clicks
  // into taps for the packages it lists.
  function toggleTouch(pkg) {
    if (!booted) return
    var list = (props.fakeTouch || []).filter(function (p) { return p !== pkg })
    if (!touchOn(pkg)) list.push(pkg)
    run(["setprop", "persist.waydroid.fake_touch", list.join(",")], "")
    props = { width: props.width, height: props.height, multiWindows: props.multiWindows, fakeTouch: list }
    needsRestart = true
  }

  property var pendingProps: []

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    refreshAll()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  Component.onCompleted: refreshAll()

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function start(): void { root.run(["show"], "Starting Android…") }
    function stop(): void { root.run(["stop"], "Stopping Android…") }
    function status(): string { return root.stateText }
  }

  Timer {
    // Fast while the popup is open, lazy otherwise: the bar icon only needs the running state.
    interval: root.opened ? 3000 : 15000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: statusClear
    interval: 8000
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: statusProc
    command: [root.backend, "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var s = JSON.parse(text)
          var prev = root.lastCpuSample
          if (prev && s.cpuUsec >= prev.cpuUsec && s.now > prev.now)
            root.cpuPercent = (s.cpuUsec - prev.cpuUsec) / ((s.now - prev.now) * 1000) * 100
          else if (s.session !== "RUNNING")
            root.cpuPercent = 0
          root.lastCpuSample = { cpuUsec: s.cpuUsec, now: s.now }
          var wasBooted = root.booted
          root.st = s
          if (!wasBooted && root.booted) {
            if (!appsProc.running) appsProc.running = true
            if (!propsProc.running) propsProc.running = true
          }
          if (s.session !== "RUNNING") root.net = null
        } catch (e) {}
      }
    }
  }

  Process {
    id: appsProc
    command: [root.backend, "apps"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { var a = JSON.parse(text); if (a.length > 0) root.apps = a } catch (e) {}
      }
    }
  }

  Process {
    id: propsProc
    command: [root.backend, "props"]
    stdout: StdioCollector {
      onStreamFinished: { try { root.props = JSON.parse(text) } catch (e) {} }
    }
  }

  Process {
    id: actionProc
    command: []
    stderr: StdioCollector { id: actionErr }
    onExited: function (code) {
      if (root.pendingProps.length > 0) {
        var next = root.pendingProps[0]
        root.pendingProps = root.pendingProps.slice(1)
        actionProc.command = [root.backend, "setprop", next[0], next[1]]
        actionProc.running = true
        return
      }
      root.busy = rootProc.running
      if (code !== 0) root.say(actionErr.text.trim() || "Waydroid refused the command")
      root.refresh()
    }
  }

  Process {
    id: rootProc
    property string mode: ""
    command: []
    stdout: StdioCollector { id: rootOut }
    stderr: StdioCollector { id: rootErr }
    onExited: function (code) {
      root.busy = actionProc.running
      if (mode === "netcheck") {
        try {
          root.net = JSON.parse(rootOut.text)
          if (!root.net.reachable) root.say("Android is not answering yet")
          else if (root.net.network && root.net.dns) root.say("Android is online")
          else if (root.net.network) root.say("Android has a network but no DNS")
          else root.say("Android lost its network — restart the session to fix it")
        } catch (e) {
          // pkexec exits 126 when the password window is dismissed.
          root.say(code === 126 ? "Network check cancelled" : (rootErr.text.trim() || "Network check failed"))
        }
      } else if (mode === "houdini") {
        if (code === 0) {
          root.say("libhoudini reinstalled — restart the session to load it")
          root.needsRestart = true
        } else {
          root.say(code === 126 ? "Reinstall cancelled" : (rootErr.text.trim().split("\n").pop() || "Reinstall failed"))
        }
      }
      root.refresh()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.androidGlyph
    foreground: !root.healthy ? root.urgent
      : root.running ? root.barForeground
      : Qt.darker(root.barForeground, 1.55)
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) root.run(["show"], "Opening Android…")
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(900))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        var key = String(t).toLowerCase()
        if (key === "r") root.refreshAll()
        else if (key === "o") root.run(["show"], "Opening Android…")
        else if (key === "s" && root.running) root.run(["stop"], "Stopping Android…")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Android"
            meta: root.stateText
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.running ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: root.androidGlyph
                color: root.running ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)

            Button {
              text: "Open"
              iconText: "󰏌"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.busy
              onClicked: root.run(["show"], root.running ? "" : "Starting Android…")
            }
            Button {
              text: "Stop"
              iconText: "󰓛"
              bordered: true
              visible: root.running
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.busy
              tooltipText: "Shut Android down and free its memory"
              onClicked: root.run(["stop"], "Stopping Android…")
            }
            Button {
              text: "Restart"
              iconText: "󰜉"
              bordered: true
              visible: root.running
              foreground: root.needsRestart ? root.urgent : root.foreground
              fontFamily: root.fontFamily
              enabled: !root.busy
              onClicked: {
                root.needsRestart = false
                root.net = null
                root.run(["restart"], "Restarting Android…")
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.actionStatus !== "" || root.needsRestart
            width: parent.width
            text: root.actionStatus !== "" ? root.actionStatus : "Restart Android to apply the change"
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ── Usage ─────────────────────────────────────────────
          Column {
            visible: root.running
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader { text: "USAGE"; foreground: root.foreground; fontFamily: root.fontFamily }

            InfoRow { label: "Memory"; value: root.formatBytes(root.st.anonBytes || 0) }
            InfoRow { label: "CPU"; value: Math.round(root.cpuPercent) + "% of a core" }
            Repeater {
              model: root.runningApps
              InfoRow {
                required property var modelData
                label: "  " + modelData.name
                value: root.formatBytes(modelData.rssKb * 1024)
                dimmed: true
              }
            }
          }

          PanelSeparator { visible: root.running; foreground: root.foreground }

          // ── Health ────────────────────────────────────────────
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader { text: "HEALTH"; foreground: root.foreground; fontFamily: root.fontFamily }

            CheckRow {
              label: "Binder module"
              ok: root.st.binder === true
              detail: root.st.binder === true ? "loaded" : "missing — check `dkms status`" + (root.st.dkms ? " (" + root.st.dkms + ")" : "")
            }
            CheckRow {
              label: "Firewall rules"
              ok: root.st.ufwRules === true || root.st.ufwActive === false
              detail: root.st.ufwActive === false ? "ufw off" : root.st.ufwRules === true ? "waydroid0 allowed" : "waydroid0 rules missing"
            }
            CheckRow {
              label: "ARM apps (libhoudini)"
              ok: root.st.houdini === true
              detail: root.st.houdini === true ? "installed" : "missing"
              actionText: "Reinstall"
              actionEnabled: root.booted
              onAction: root.runRoot(["houdini", root.scriptDir, String(root.props.androidVersion || "")], "Reinstalling libhoudini…")
            }
            CheckRow {
              label: "Network in Android"
              ok: root.net === null ? true : (root.net.reachable && root.net.network && root.net.dns)
              unknown: root.net === null
              detail: root.net === null ? "not checked"
                : !root.net.reachable ? "Android not ready"
                : root.net.network && root.net.dns ? "online"
                : root.net.network ? "no DNS" : "no network"
              actionText: "Check"
              actionEnabled: root.booted
              onAction: root.runRoot(["netcheck"], "Checking Android's network…")
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ── Display ───────────────────────────────────────────
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader { text: "DISPLAY"; foreground: root.foreground; fontFamily: root.fontFamily }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: [
                  { label: "Auto", w: "", h: "" },
                  { label: "1920×1080", w: "1920", h: "1080" },
                  { label: "1280×720", w: "1280", h: "720" }
                ]
                Button {
                  required property var modelData
                  text: modelData.label
                  bordered: true
                  selected: String(root.props.width || "") === modelData.w
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: root.booted && !root.busy
                  onClicked: root.setResolution(modelData.w, modelData.h)
                }
              }
            }

            Button {
              text: root.props.multiWindows ? "Multi-window: on" : "Multi-window: off"
              bordered: true
              selected: root.props.multiWindows === true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.booted && !root.busy
              tooltipText: "Each Android app gets its own window, so it tiles like any other"
              onClicked: root.setMultiWindows(!root.props.multiWindows)
            }

            Text {
              visible: !root.booted
              width: parent.width
              text: "Start Android to change these"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { visible: root.apps.length > 0; foreground: root.foreground }

          // ── Apps ──────────────────────────────────────────────
          Column {
            visible: root.apps.length > 0
            width: parent.width
            spacing: Style.space(2)

            PanelSectionHeader { text: "APPS"; foreground: root.foreground; fontFamily: root.fontFamily }

            Repeater {
              model: root.apps
              AppRow {
                required property var modelData
                label: modelData.name
                touch: root.touchOn(modelData.pkg)
                onToggleTouch: root.toggleTouch(modelData.pkg)
                onActivated: {
                  root.run(["launch", modelData.pkg], "Opening " + modelData.name + "…")
                  root.close()
                }
              }
            }
          }

          PanelSeparator { visible: root.readmePath !== ""; foreground: root.foreground }

          LinkRow {
            visible: root.readmePath !== ""
            label: "Open your notes"
            onActivated: {
              Quickshell.execDetached(["xdg-open", root.readmePath])
              root.close()
            }
          }
        }
      }
    }
  }

  component InfoRow: Item {
    id: infoRow
    property string label: ""
    property string value: ""
    property bool dimmed: false
    width: parent ? parent.width : 0
    implicitHeight: labelText.implicitHeight

    Text {
      id: labelText
      anchors.left: parent.left
      anchors.right: valueText.left
      anchors.rightMargin: Style.space(8)
      text: infoRow.label
      elide: Text.ElideRight
      color: infoRow.dimmed ? root.dim : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      id: valueText
      anchors.right: parent.right
      text: infoRow.value
      color: infoRow.dimmed ? root.dim : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component AppRow: Item {
    id: appRow
    property string label: ""
    property bool touch: false
    signal activated()
    signal toggleTouch()
    width: parent ? parent.width : 0
    implicitHeight: Math.max(appText.implicitHeight + Style.space(6), touchButton.implicitHeight)

    Text {
      id: appText
      anchors.left: parent.left
      anchors.right: touchButton.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: appRow.label
      elide: Text.ElideRight
      color: root.foreground
      opacity: appMouse.containsMouse ? 1.0 : 0.75
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    MouseArea {
      id: appMouse
      anchors.fill: appText
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: appRow.activated()
    }
    Button {
      id: touchButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: "Touch"
      iconText: "󰆽"
      bordered: appRow.touch
      selected: appRow.touch
      foreground: appRow.touch ? root.foreground : root.dim
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      verticalPadding: Style.space(2)
      enabled: root.booted && !root.busy
      tooltipText: appRow.touch ? "Clicks reach this app as finger taps" : "Send clicks to this app as finger taps (for games that ignore the mouse)"
      onClicked: appRow.toggleTouch()
    }
  }

  component LinkRow: Item {
    id: linkRow
    property string label: ""
    signal activated()
    width: parent ? parent.width : 0
    implicitHeight: linkText.implicitHeight + Style.space(6)

    Text {
      id: linkText
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      text: linkRow.label
      elide: Text.ElideRight
      color: root.foreground
      opacity: linkMouse.containsMouse ? 1.0 : 0.75
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    MouseArea {
      id: linkMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: linkRow.activated()
    }
  }

  component CheckRow: Item {
    id: checkRow
    property string label: ""
    property string detail: ""
    property bool ok: true
    property bool unknown: false
    property string actionText: ""
    property bool actionEnabled: true
    signal action()
    width: parent ? parent.width : 0
    implicitHeight: Math.max(checkText.implicitHeight + detailText.implicitHeight, actionButton.visible ? actionButton.implicitHeight : 0)

    Text {
      id: mark
      anchors.left: parent.left
      anchors.top: parent.top
      width: Style.space(18)
      text: checkRow.unknown ? "󰄰" : checkRow.ok ? "󰄬" : "󰅖"
      color: checkRow.unknown ? root.dim : checkRow.ok ? root.foreground : root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    Text {
      id: checkText
      anchors.left: mark.right
      anchors.right: actionButton.visible ? actionButton.left : parent.right
      anchors.top: parent.top
      text: checkRow.label
      elide: Text.ElideRight
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      id: detailText
      anchors.left: checkText.left
      anchors.right: checkText.right
      anchors.top: checkText.bottom
      text: checkRow.detail
      elide: Text.ElideRight
      color: checkRow.ok || checkRow.unknown ? root.dim : root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    Button {
      id: actionButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: checkRow.actionText !== ""
      text: checkRow.actionText
      bordered: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      enabled: checkRow.actionEnabled && !root.busy
      onClicked: checkRow.action()
    }
  }
}
