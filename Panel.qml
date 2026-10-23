import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Single bar widget: the icon shown is live CPU package power draw (watts,
// averaged between polls of Intel RAPL's counters - see omarchy-cpu-power). Clicking it opens one popup with
// the power-profile picker on top and session power stats below.
Panel {
  id: root
  moduleName: "marionuevo.power"
  ipcTarget: "marionuevo.power"
  manageIpc: false

  // ---- Power profiles ----
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false

  // ---- CPU power draw ----
  property real watts: 0
  property bool loaded: false
  property real sampleCount: 0
  property real sumWatts: 0
  property real minWatts: -1
  property real maxWatts: -1
  property real pl1Watts: 0
  property real pl2Watts: 0
  property real mhz: 0

  // ---- GPU power draw (NVIDIA, via nvidia-smi - see omarchy-gpu-power) ----
  // gpuPresent stays false on machines with no NVIDIA GPU, which hides every
  // GPU element rather than showing a dead "—".
  property bool gpuPresent: false
  property bool gpuLoaded: false
  property real gpuWatts: 0
  property real gpuMhz: 0
  property real gpuLimitWatts: 0
  property string gpuPstate: ""
  property real gpuUtil: 0
  property real gpuSampleCount: 0
  property real gpuSumWatts: 0
  property real gpuMinWatts: -1
  property real gpuMaxWatts: -1

  // ---- RAM power draw (RAPL "dram" zone, from the same omarchy-cpu-power
  //      reading) ----
  // ramPresent stays false where RAPL has no dram zone (most client CPUs),
  // which hides every RAM element just like the GPU ones.
  property bool ramPresent: false
  property real ramWatts: 0
  property real ramLimitWatts: 0
  property real ramSampleCount: 0
  property real ramSumWatts: 0
  property real ramMinWatts: -1
  property real ramMaxWatts: -1

  // The previous omarchy-cpu-power reading; watts are the energy spent
  // between it and the next one.
  property var lastEnergy: null

  readonly property real avgWatts: sampleCount > 0 ? sumWatts / sampleCount : 0
  readonly property real ramAvgWatts: ramSampleCount > 0 ? ramSumWatts / ramSampleCount : 0
  readonly property real gpuAvgWatts: gpuSampleCount > 0 ? gpuSumWatts / gpuSampleCount : 0

  // Alert level, driven purely by proximity to this CPU's own RAPL limits —
  // no color coding (theme colors only). 1 = near sustained limit
  // (outlined), 2 = at/over sustained limit or over boost limit (flashing).
  readonly property int alertLevel: {
    if (pl1Watts <= 0) return 0
    if (watts >= pl1Watts) return 2
    if (watts >= pl1Watts * 0.9) return 1
    return 0
  }

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles)
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  function profileLabel(name) {
    return Model.profileLabel(name)
  }

  function refresh() {
    if (!profilesProc.running) profilesProc.running = true
    if (!powerProc.running) powerProc.running = true
    if (!freqProc.running) freqProc.running = true
    if (!gpuProc.running) gpuProc.running = true
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Preserve the last known profile list across transient empty payloads
    // so the buttons don't blink out.
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
    if (opened && !cursorActive) {
      var idx = profiles.indexOf(activeProfile)
      if (idx >= 0) profileIndex = idx
    }
  }

  function setProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", "ac", profile]
    actionProc.running = true
  }

  // Lines: monotonic ns, CPU energy µJ, then RAM energy µJ and RAM limit W
  // where RAPL has a dram zone. A counter that went backwards wrapped
  // around: that interval is skipped.
  function parseWatts(raw) {
    var lines = String(raw || "").trim().split("\n")
    var now = { t: Number(lines[0]), cpu: Number(lines[1]),
                ram: lines.length >= 4 ? Number(lines[2]) : NaN }
    if (!isFinite(now.t) || !isFinite(now.cpu)) return
    var last = lastEnergy
    lastEnergy = now
    if (lines.length >= 4) {
      var lim = parseFloat(lines[3])
      ramLimitWatts = isNaN(lim) ? 0 : lim
    }
    if (!last || now.t <= last.t) return
    var seconds = (now.t - last.t) / 1e9

    var v = (now.cpu - last.cpu) / 1e6 / seconds
    if (v <= 0) return
    watts = v
    loaded = true
    sampleCount += 1
    sumWatts += v
    if (minWatts < 0 || v < minWatts) minWatts = v
    if (v > maxWatts) maxWatts = v

    var r = (now.ram - last.ram) / 1e6 / seconds
    if (!isFinite(r) || r <= 0) return
    ramPresent = true
    ramWatts = r
    ramSampleCount += 1
    ramSumWatts += r
    if (ramMinWatts < 0 || r < ramMinWatts) ramMinWatts = r
    if (r > ramMaxWatts) ramMaxWatts = r
  }

  function parseLimits(raw) {
    var lines = String(raw || "").split("\n")
    var pl1 = parseFloat(lines[0])
    var pl2 = parseFloat(lines[1])
    if (!isNaN(pl1) && pl1 > 0) pl1Watts = pl1 / 1000000
    if (!isNaN(pl2) && pl2 > 0) pl2Watts = pl2 / 1000000
  }

  function parseFreq(raw) {
    var v = parseFloat(String(raw || "").trim())
    if (isNaN(v) || v <= 0) return
    mhz = v
  }

  // "watts,sm_mhz,limit_watts,pstate,util" — empty output means no GPU.
  function parseGpu(raw) {
    var line = String(raw || "").trim()
    if (line === "") return
    var f = line.split(",")
    if (f.length < 5) return
    var w = parseFloat(f[0])
    if (isNaN(w) || w <= 0) return

    gpuPresent = true
    gpuLoaded = true
    gpuWatts = w
    gpuSampleCount += 1
    gpuSumWatts += w
    if (gpuMinWatts < 0 || w < gpuMinWatts) gpuMinWatts = w
    if (w > gpuMaxWatts) gpuMaxWatts = w

    var m = parseFloat(f[1])
    if (!isNaN(m) && m > 0) gpuMhz = m
    var lim = parseFloat(f[2])
    if (!isNaN(lim) && lim > 0) gpuLimitWatts = lim
    gpuPstate = f[3]
    var u = parseFloat(f[4])
    if (!isNaN(u)) gpuUtil = u
  }

  readonly property string tooltipText: {
    if (!loaded) return "CPU power draw\nClick for power modes & stats"
    var t = "CPU: " + watts.toFixed(1) + " W · " + profileLabel(activeProfile)
    if (gpuPresent && gpuLoaded)
      t += "\nGPU: " + gpuWatts.toFixed(1) + " W · " + gpuPstate + " · " + gpuUtil.toFixed(0) + "%"
    if (ramPresent)
      t += "\nRAM: " + ramWatts.toFixed(1) + " W" + (ramLimitWatts > 0 ? " · capped at " + ramLimitWatts.toFixed(1) + " W" : "")
    return t + "\nClick for power modes & stats"
  }

  IpcHandler {
    target: "marionuevo.power"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }

  Component.onCompleted: {
    refresh()
    syncClickRegistration()
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: powerProc
    command: ["omarchy-cpu-power"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseWatts(text) }
  }

  Process {
    id: freqProc
    command: ["omarchy-cpu-freq"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseFreq(text) }
  }

  Process {
    id: gpuProc
    command: ["omarchy-gpu-power"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseGpu(text) }
  }

  Process {
    id: limitsProc
    command: ["cat", "/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw", "/sys/class/powercap/intel-rapl:0/constraint_1_power_limit_uw"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseLimits(text) }
    running: true
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  // Runs continuously (not just while opened) since the bar icon itself is
  // the live wattage reading.
  Timer { interval: 2000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

  // ---- Bar icon: a content-sized pill, since BarIconButton's slot is a
  // fixed single-glyph square and clips/overlaps variable-width text like
  // "35.4W". ----
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property real barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property real horizontalMargin: 8.5

  visible: true
  implicitWidth: vertical ? barSize : Math.max(12, pillRow.implicitWidth + horizontalMargin * 2)
  implicitHeight: vertical ? pillRow.implicitHeight + horizontalMargin * 2 : barSize

  property var registeredBar: null
  function syncClickRegistration() {
    if (registeredBar && registeredBar.unregisterClickTarget)
      registeredBar.unregisterClickTarget(root)
    registeredBar = root.bar
    if (registeredBar && registeredBar.registerClickTarget)
      registeredBar.registerClickTarget(root)
  }
  onBarChanged: syncClickRegistration()
  Component.onDestruction: {
    if (registeredBar && registeredBar.unregisterClickTarget)
      registeredBar.unregisterClickTarget(root)
  }

  // Outline appears near the sustained power limit; pulses (flashes) at or
  // over it. Always drawn in the bar's own foreground color — intensity via
  // opacity/visibility, never a different hue.
  Rectangle {
    id: alertOutline
    anchors.fill: parent
    anchors.margins: 1
    radius: Style.space(4)
    color: "transparent"
    border.width: 1
    border.color: root.bar ? root.bar.foreground : Color.foreground
    visible: root.alertLevel >= 1

    SequentialAnimation on opacity {
      running: root.alertLevel >= 2
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { from: 1.0; to: 0.15; duration: 500; easing.type: Easing.InOutSine }
      NumberAnimation { from: 0.15; to: 1.0; duration: 500; easing.type: Easing.InOutSine }
    }
    // Static (non-flashing) partial opacity for the "near limit" tier.
    opacity: root.alertLevel >= 2 ? 1.0 : (root.alertLevel === 1 ? 0.6 : 0)
    Behavior on opacity { enabled: root.alertLevel < 2; NumberAnimation { duration: 200 } }
  }

  // Icon+value pairs (CPU, then GPU and RAM where present) in one pill. The outer spacing is wider
  // than the inner so each icon visually binds to its own number instead of
  // the four items reading as one undifferentiated run.
  Row {
    id: pillRow
    anchors.centerIn: parent
    spacing: Style.space(10)

    Row {
      spacing: Style.space(4)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "󱐋"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.bar.iconFont
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: !root.loaded ? "…" : root.watts.toFixed(1) + "W"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        renderType: Text.NativeRendering
      }
    }

    Row {
      spacing: Style.space(4)
      visible: root.gpuPresent

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "󰢮"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.bar.iconFont
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: !root.gpuLoaded ? "…" : root.gpuWatts.toFixed(1) + "W"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        renderType: Text.NativeRendering
      }
    }

    Row {
      spacing: Style.space(4)
      visible: root.ramPresent

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: ""
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.bar.iconFont
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.ramWatts.toFixed(1) + "W"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        renderType: Text.NativeRendering
      }
    }
  }

  MouseArea {
    id: pillArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltipText)
    onExited: if (root.bar) root.bar.hideTooltip(root)
    onClicked: function(mouse) {
      if (mouse.button === Qt.LeftButton) root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: pillArea
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ================= Power modes (top) =================

        // ---------- Hero: profile icon · title/current mode ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(modeHeroIcon.implicitHeight, modeHeroLabels.implicitHeight)

          Text {
            id: modeHeroIcon
            text: root.profileIcon(root.activeProfile)
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: modeHeroLabels
            anchors.left: modeHeroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Power Mode"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.profileLabel(root.activeProfile).toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Row {
          id: profileRow
          width: parent.width
          spacing: Style.space(6)

          readonly property real cellWidth: root.profiles.length > 0
            ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
            : 0

          Repeater {
            model: root.profiles
            Button {
              required property var modelData
              required property int index
              width: profileRow.cellWidth
              iconText: root.profileIcon(String(modelData))
              iconSize: Style.font.title
              text: root.profileLabel(String(modelData))
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              active: root.activeProfile === modelData
              hasCursor: root.cursorActive && root.profileIndex === index
              onClicked: root.setProfile(modelData)
              onHovered: function(h) {
                if (h) {
                  root.cursorActive = true
                  root.profileIndex = index
                }
              }
            }
          }
        }

        // ================= Power draw (bottom) =================

        PanelSeparator {
          foreground: root.bar.foreground
        }

        Row {
          id: powerStatsRow
          width: parent.width
          spacing: Style.space(10)

          readonly property real cellWidth: (width - spacing) / 2

          Column {
            width: powerStatsRow.cellWidth
            spacing: Style.space(2)

            Row {
              spacing: Style.space(6)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "󱐋"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "CPU Power"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
            }
            Text {
              text: !root.loaded ? "Loading…" : root.watts.toFixed(1) + " W"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            width: powerStatsRow.cellWidth
            spacing: Style.space(2)

            Row {
              spacing: Style.space(6)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "󰐰"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "CPU Frequency"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
            }
            Text {
              text: root.mhz > 0 ? (root.mhz / 1000).toFixed(2) + " GHz" : "Loading…"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // Same two-cell shape as the CPU row above, so the four readings line
        // up in a 2x2 grid. Hidden entirely when there's no NVIDIA GPU.
        Row {
          id: gpuStatsRow
          width: parent.width
          spacing: Style.space(10)
          visible: root.gpuPresent

          readonly property real cellWidth: (width - spacing) / 2

          Column {
            width: gpuStatsRow.cellWidth
            spacing: Style.space(2)

            Row {
              spacing: Style.space(6)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "󰢮"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "GPU Power"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
            }
            Text {
              text: !root.gpuLoaded ? "Loading…" : root.gpuWatts.toFixed(1) + " W"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            width: gpuStatsRow.cellWidth
            spacing: Style.space(2)

            Row {
              spacing: Style.space(6)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "󰐰"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "GPU Frequency"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
            }
            Text {
              text: root.gpuMhz > 0
                ? (root.gpuMhz / 1000).toFixed(2) + " GHz"
                  + (root.gpuPstate !== "" ? " · " + root.gpuPstate : "")
                : "Loading…"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // RAM power on its own row. Hidden where RAPL has no dram zone.
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.ramPresent

          Row {
            spacing: Style.space(6)
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: ""
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "RAM Power"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }
          }
          Text {
            text: root.ramWatts.toFixed(1) + " W" + (root.ramLimitWatts > 0 ? " · capped at " + root.ramLimitWatts.toFixed(1) + " W" : "")
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Session min/avg/max as a small table: one row per statistic, one
        // value column per device. The GPU column collapses away when there's
        // no GPU, leaving the original single-column layout.
        Column {
          id: sessionTable
          width: parent.width
          spacing: Style.spacing.xs

          readonly property real labelWidth: 60
          readonly property real valueWidth: 80
          readonly property color mutedForeground: Qt.rgba(
            root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.6)

          PanelSectionHeader { foreground: root.bar.foreground; text: "THIS SESSION" }

          Row {
            width: parent.width
            spacing: Style.spacing.sm
            visible: root.gpuPresent || root.ramPresent
            Item { width: sessionTable.labelWidth; height: 1 }
            Text {
              text: "CPU"
              color: sessionTable.mutedForeground
              font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall
              font.bold: true
              width: sessionTable.valueWidth
            }
            Text {
              text: "GPU"
              color: sessionTable.mutedForeground
              font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall
              font.bold: true
              width: sessionTable.valueWidth
              visible: root.gpuPresent
            }
            Text {
              text: "RAM"
              color: sessionTable.mutedForeground
              font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall
              font.bold: true
              width: sessionTable.valueWidth
              visible: root.ramPresent
            }
          }

          Repeater {
            model: [
              { label: "Min", cpu: root.minWatts < 0 ? "—" : root.minWatts.toFixed(1) + " W",
                gpu: root.gpuMinWatts < 0 ? "—" : root.gpuMinWatts.toFixed(1) + " W",
                ram: root.ramMinWatts < 0 ? "—" : root.ramMinWatts.toFixed(1) + " W" },
              { label: "Avg", cpu: root.sampleCount === 0 ? "—" : root.avgWatts.toFixed(1) + " W",
                gpu: root.gpuSampleCount === 0 ? "—" : root.gpuAvgWatts.toFixed(1) + " W",
                ram: root.ramSampleCount === 0 ? "—" : root.ramAvgWatts.toFixed(1) + " W" },
              { label: "Max", cpu: root.maxWatts < 0 ? "—" : root.maxWatts.toFixed(1) + " W",
                gpu: root.gpuMaxWatts < 0 ? "—" : root.gpuMaxWatts.toFixed(1) + " W",
                ram: root.ramMaxWatts < 0 ? "—" : root.ramMaxWatts.toFixed(1) + " W" }
            ]

            Row {
              id: sessionRow
              required property var modelData
              width: sessionTable.width
              spacing: Style.spacing.sm

              Text {
                text: sessionRow.modelData.label
                color: sessionTable.mutedForeground
                font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall
                width: sessionTable.labelWidth
              }
              Text {
                text: sessionRow.modelData.cpu
                color: root.bar.foreground
                font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall
                width: sessionTable.valueWidth
              }
              Text {
                text: sessionRow.modelData.gpu
                color: root.bar.foreground
                font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall
                width: sessionTable.valueWidth
                visible: root.gpuPresent
              }
              Text {
                text: sessionRow.modelData.ram
                color: root.bar.foreground
                font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall
                width: sessionTable.valueWidth
                visible: root.ramPresent
              }
            }
          }
        }

        Column {
          id: limitsTable
          width: parent.width
          spacing: Style.spacing.xs

          // Wide enough for the longest label ("CPU sustained (PL1)"). The
          // labels also elide, so a longer one can never overdraw the value
          // column the way an unbounded Text would.
          readonly property real labelWidth: 185
          readonly property color mutedForeground: Qt.rgba(
            root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.6)

          PanelSectionHeader { foreground: root.bar.foreground; text: "LIMITS" }

          Repeater {
            model: [
              { label: "CPU sustained (PL1)", value: root.pl1Watts > 0 ? root.pl1Watts.toFixed(0) + " W" : "—", shown: true },
              { label: "CPU boost (PL2)", value: root.pl2Watts > 0 ? root.pl2Watts.toFixed(0) + " W" : "—", shown: true },
              { label: "GPU cap", value: root.gpuLimitWatts > 0 ? root.gpuLimitWatts.toFixed(0) + " W" : "—", shown: root.gpuPresent },
              // Only while some daemon (imac-fand on an iMac) has it enabled.
              { label: "RAM cap", value: root.ramLimitWatts.toFixed(1) + " W", shown: root.ramLimitWatts > 0 }
            ]

            Row {
              id: limitRow
              required property var modelData
              width: limitsTable.width
              spacing: Style.spacing.sm
              visible: limitRow.modelData.shown

              Text {
                text: limitRow.modelData.label
                color: limitsTable.mutedForeground
                font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall
                width: limitsTable.labelWidth
                elide: Text.ElideRight
              }
              Text {
                text: limitRow.modelData.value
                color: root.bar.foreground
                font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }
      }
    }
  }
}
