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

  // ---- GPU power draw (nvidia-smi, or the iMac's SMC - see omarchy-gpu-power) ----
  // gpuPresent stays false on machines with no GPU reading, which hides every
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

  // ---- Whole-machine power draw (see omarchy-system-power) ----
  // totalPresent stays false where nothing measures it (anything but an iMac
  // running imac-fand so far), which hides every total element.
  property bool totalPresent: false
  property real totalWatts: 0
  property real totalSampleCount: 0
  property real totalSumWatts: 0
  property real totalMinWatts: -1
  property real totalMaxWatts: -1

  // The previous omarchy-cpu-power reading; watts are the energy spent
  // between it and the next one.
  property var lastEnergy: null

  readonly property real avgWatts: sampleCount > 0 ? sumWatts / sampleCount : 0
  readonly property real ramAvgWatts: ramSampleCount > 0 ? ramSumWatts / ramSampleCount : 0
  readonly property real gpuAvgWatts: gpuSampleCount > 0 ? gpuSumWatts / gpuSampleCount : 0
  readonly property real totalAvgWatts: totalSampleCount > 0 ? totalSumWatts / totalSampleCount : 0

  // ---- Last two minutes: one {t, cpu, gpu, ram, total} sample (watts, null where
  //      there is no reading) per CPU poll. Kept while the popup is closed,
  //      so its chart is already full when it opens. ----
  property var history: []
  readonly property int windowMs: 120000

  // A new array each time, so bindings on `history` see the change.
  function record(cpu, gpu, ram, total) {
    var now = Date.now()
    var cutoff = now - windowMs
    var kept = []
    for (var i = 0; i < history.length; i++)
      if (history[i].t >= cutoff) kept.push(history[i])
    kept.push({ t: now, cpu: cpu, gpu: gpu, ram: ram, total: total })
    history = kept
  }

  // Series colors come from the theme's own palette, so they follow theme
  // switches; the same ones as omarchy-imac-stats' temperature chart.
  property var themeColors: ({})

  function parseColors(raw) {
    var out = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z0-9_]+)\s*=\s*["'](#[0-9A-Fa-f]{6})["']/)
      if (m) out[m[1]] = m[2]
    }
    return out
  }

  function themeColor(names, fallback) {
    for (var i = 0; i < names.length; i++)
      if (themeColors[names[i]]) return themeColors[names[i]]
    return fallback
  }

  // Only the devices this machine has a reading for.
  readonly property var series: {
    var out = [{ key: "cpu", label: "CPU", color: themeColor(["blue", "color4"], "#7aa2f7") }]
    if (gpuPresent) out.push({ key: "gpu", label: "GPU", color: themeColor(["yellow", "color3"], "#e0af68") })
    if (ramPresent) out.push({ key: "ram", label: "RAM", color: themeColor(["magenta", "color5"], "#ad8ee6") })
    // The sum of everything, so no device's color: the foreground, dashed.
    if (totalPresent) out.push({ key: "total", label: "Total", dashed: true,
                                 color: root.bar ? root.bar.foreground : Color.foreground })
    return out
  }

  // Where the pointer is over the plot, 0 (two minutes ago) to 1 (now); -1 off it.
  property real hoverFrac: -1
  readonly property int hoverIndex: hoverFrac < 0 ? -1 : nearestSample(hoverFrac)
  readonly property var shownSample: history.length === 0 ? null
    : history[hoverIndex >= 0 ? hoverIndex : history.length - 1]
  readonly property var chartRange: wattRange(history)

  function windowEnd() {
    return history.length > 0 ? history[history.length - 1].t : Date.now()
  }

  function nearestSample(frac) {
    var t = windowEnd() - windowMs * (1 - frac)
    var best = -1
    for (var i = 0; i < history.length; i++)
      if (best < 0 || Math.abs(history[i].t - t) < Math.abs(history[best].t - t)) best = i
    return best
  }

  // From 0 W up to a round step above the highest reading, at most five
  // steps: power has a real zero, unlike a temperature.
  function wattRange(samples) {
    var hi = 0
    for (var i = 0; i < samples.length; i++)
      for (var j = 0; j < series.length; j++) {
        var v = samples[i][series[j].key]
        if (v !== null && v !== undefined) hi = Math.max(hi, v)
      }
    var top = Math.max(hi * 1.08, 4)
    var steps = [1, 2, 5, 10, 20, 25, 50, 100, 200]
    var step = steps[steps.length - 1]
    for (var k = 0; k < steps.length; k++)
      if (top / steps[k] <= 5) { step = steps[k]; break }
    var max = Math.max(Math.ceil(top / step), 2) * step
    var ticks = []
    for (var t = 0; t <= max; t += step) ticks.push(t)
    return { min: 0, max: max, ticks: ticks }
  }

  function fmtWatts(v) {
    return v === null || v === undefined ? "—" : v.toFixed(1) + " W"
  }

  readonly property real plotPad: Style.space(4)

  function chartY(v, h) {
    var r = chartRange
    return h - plotPad - (v - r.min) / (r.max - r.min) * (h - 2 * plotPad)
  }

  function chartX(t, w) {
    return w - (windowEnd() - t) / windowMs * w
  }

  function paintChart(ctx, w, h) {
    ctx.reset()
    var fg = root.bar ? root.bar.foreground : Color.foreground
    ctx.lineWidth = 1
    ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.1)
    for (var g = 0; g < chartRange.ticks.length; g++) {
      var gy = Math.round(chartY(chartRange.ticks[g], h)) + 0.5
      ctx.beginPath()
      ctx.moveTo(0, gy)
      ctx.lineTo(w, gy)
      ctx.stroke()
    }

    ctx.lineWidth = 2
    ctx.lineJoin = "round"
    ctx.lineCap = "round"
    for (var s = 0; s < series.length; s++) {
      ctx.strokeStyle = series[s].color
      ctx.setLineDash(series[s].dashed ? [5, 4] : [])
      ctx.beginPath()
      var drawing = false
      for (var i = 0; i < history.length; i++) {
        var v = history[i][series[s].key]
        if (v === null || v === undefined) { drawing = false; continue }
        var x = chartX(history[i].t, w), y = chartY(v, h)
        if (drawing) ctx.lineTo(x, y)
        else ctx.moveTo(x, y)
        drawing = true
      }
      ctx.stroke()
    }
    ctx.setLineDash([])

    if (hoverIndex < 0) return
    var sample = history[hoverIndex]
    var hx = Math.round(chartX(sample.t, w)) + 0.5
    ctx.lineWidth = 1
    ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.35)
    ctx.beginPath()
    ctx.moveTo(hx, 0)
    ctx.lineTo(hx, h)
    ctx.stroke()
    ctx.lineWidth = 2
    ctx.strokeStyle = Color.popups.background
    for (var d = 0; d < series.length; d++) {
      var dv = sample[series[d].key]
      if (dv === null || dv === undefined) continue
      ctx.fillStyle = series[d].color
      ctx.beginPath()
      ctx.arc(hx, chartY(dv, h), 4, 0, 2 * Math.PI)
      ctx.fill()
      ctx.stroke()
    }
  }

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
    if (!totalProc.running) totalProc.running = true
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
    var ramOk = isFinite(r) && r > 0
    if (ramOk) {
      ramPresent = true
      ramWatts = r
      ramSampleCount += 1
      ramSumWatts += r
      if (ramMinWatts < 0 || r < ramMinWatts) ramMinWatts = r
      if (r > ramMaxWatts) ramMaxWatts = r
    }
    // The GPU and the total are polled by their own processes; their latest
    // readings go with this one.
    record(v, gpuPresent && gpuLoaded ? gpuWatts : null, ramOk ? r : null,
           totalPresent ? totalWatts : null)
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
    gpuUtil = isNaN(u) ? -1 : u
  }

  // One number in watts; empty output means nothing measures it.
  function parseTotal(raw) {
    var w = parseFloat(String(raw || "").trim())
    if (isNaN(w) || w <= 0) return
    totalPresent = true
    totalWatts = w
    totalSampleCount += 1
    totalSumWatts += w
    if (totalMinWatts < 0 || w < totalMinWatts) totalMinWatts = w
    if (w > totalMaxWatts) totalMaxWatts = w
  }

  readonly property string tooltipText: {
    if (!loaded) return "CPU power draw\nClick for power modes & stats"
    var t = "CPU: " + watts.toFixed(1) + " W · " + profileLabel(activeProfile)
    if (gpuPresent && gpuLoaded)
      t += "\nGPU: " + gpuWatts.toFixed(1) + " W" + (gpuPstate !== "" ? " · " + gpuPstate : "") +
        (gpuUtil >= 0 ? " · " + gpuUtil.toFixed(0) + "%" : "")
    if (ramPresent)
      t += "\nRAM: " + ramWatts.toFixed(1) + " W" + (ramLimitWatts > 0 ? " · capped at " + ramLimitWatts.toFixed(1) + " W" : "")
    if (totalPresent)
      t += "\nTotal: " + totalWatts.toFixed(1) + " W"
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
      themeColorsFile.reload()
    } else {
      hoverFrac = -1
    }
  }

  FileView {
    id: themeColorsFile
    path: Color.currentThemePath + "/colors.toml"
    printErrors: false
    onLoaded: root.themeColors = root.parseColors(text())
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
    id: totalProc
    command: ["omarchy-system-power"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseTotal(text) }
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

  // Widest values the pill can show, so the widget keeps a fixed width and
  // its bar neighbors don't shift as the numbers change: CPU (PL2) and GPU
  // stay under 1000 W, RAM under 100 W.
  TextMetrics {
    id: widestWatts
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.bodySmall
    text: "100.0W"
  }

  TextMetrics {
    id: widestRamWatts
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.bodySmall
    text: "88.8W"
  }

  // Icon+value pairs (CPU, then GPU and RAM where present) in one pill, a
  // hairline between them. The outer spacing is wider than the inner so each
  // icon visually binds to its own number instead of the items reading as one
  // undifferentiated run.
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
        width: widestWatts.width
        horizontalAlignment: Text.AlignRight
        text: !root.loaded ? "…" : root.watts.toFixed(1) + "W"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        renderType: Text.NativeRendering
      }
    }

    Hairline { visible: root.gpuPresent }

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
        width: widestWatts.width
        horizontalAlignment: Text.AlignRight
        text: !root.gpuLoaded ? "…" : root.gpuWatts.toFixed(1) + "W"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        renderType: Text.NativeRendering
      }
    }

    Hairline { visible: root.ramPresent }

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
        width: widestRamWatts.width
        horizontalAlignment: Text.AlignRight
        text: root.ramWatts.toFixed(1) + "W"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        renderType: Text.NativeRendering
      }
    }
  }

  // The line between readings; marionuevo.separator draws a stronger one
  // between widgets.
  component Hairline: Rectangle {
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    width: 1
    height: Math.round(root.barSize * 0.45)
    color: root.bar ? root.bar.foreground : Color.foreground
    opacity: 0.3
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

        // RAM and whole-machine power, the same two-cell shape again. Each
        // hides where there's no reading for it (no RAPL dram zone, nothing
        // measuring the total).
        Row {
          id: ramTotalRow
          width: parent.width
          spacing: Style.space(10)
          visible: root.ramPresent || root.totalPresent

          readonly property real cellWidth: (width - spacing) / 2

          Column {
            width: ramTotalRow.cellWidth
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

          Column {
            width: ramTotalRow.cellWidth
            spacing: Style.space(2)
            visible: root.totalPresent

            Row {
              spacing: Style.space(6)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "󰚥"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Total Power"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
            }
            Text {
              text: root.totalWatts.toFixed(1) + " W"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // ---------- Last two minutes ----------
        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader { foreground: root.bar.foreground; text: "LAST 2 MINUTES" }

          // The legend carries the numbers: the hovered sample's, or the latest.
          Item {
            width: parent.width
            implicitHeight: legendRow.implicitHeight

            Flow {
              id: legendRow
              width: parent.width - legendWhen.implicitWidth - Style.space(12)
              spacing: Style.space(12)

              Repeater {
                model: root.series

                Row {
                  required property var modelData
                  spacing: Style.space(5)

                  Item {
                    width: Style.space(12)
                    height: 2
                    anchors.verticalCenter: parent.verticalCenter

                    Rectangle {
                      width: modelData.dashed ? parent.width * 0.4 : parent.width
                      height: parent.height
                      radius: 1
                      color: modelData.color
                    }
                    Rectangle {
                      visible: modelData.dashed === true
                      x: parent.width * 0.6
                      width: parent.width * 0.4
                      height: parent.height
                      radius: 1
                      color: modelData.color
                    }
                  }

                  Text {
                    text: modelData.label + " " + root.fmtWatts(root.shownSample ? root.shownSample[modelData.key] : null)
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }

            Text {
              id: legendWhen
              anchors.right: parent.right
              anchors.top: parent.top
              text: root.hoverIndex < 0 || root.hoverIndex === root.history.length - 1 ? "now"
                : Math.round((root.windowEnd() - root.history[root.hoverIndex].t) / 1000) + " s ago"
              color: root.bar.foreground
              opacity: 0.45
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Item {
            id: chart
            width: parent.width
            height: Style.space(110)

            readonly property real axisWidth: Style.space(32)

            Repeater {
              model: root.chartRange.ticks

              Text {
                required property var modelData
                x: 0
                width: chart.axisWidth - Style.space(6)
                y: root.chartY(modelData, chart.height) - height / 2
                horizontalAlignment: Text.AlignRight
                text: modelData + "W"
                color: root.bar.foreground
                opacity: 0.45
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Canvas {
              id: plot
              x: chart.axisWidth
              width: chart.width - chart.axisWidth
              height: chart.height

              // Anything the picture depends on; a change repaints it.
              readonly property var inputs: [root.history, root.hoverIndex, root.series, root.opened]
              onInputsChanged: requestPaint()
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()
              onPaint: root.paintChart(getContext("2d"), width, height)
            }

            MouseArea {
              anchors.fill: plot
              hoverEnabled: true
              onPositionChanged: function(mouse) {
                root.hoverFrac = Math.max(0, Math.min(1, mouse.x / plot.width))
              }
              onExited: root.hoverFrac = -1
            }
          }

          Item {
            width: parent.width
            implicitHeight: minus2.implicitHeight

            Text {
              id: minus2
              x: chart.axisWidth
              text: "2 min ago"
              color: root.bar.foreground
              opacity: 0.45
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              x: chart.axisWidth + (parent.width - chart.axisWidth - width) / 2
              text: "1 min"
              color: root.bar.foreground
              opacity: 0.45
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.right: parent.right
              text: "now"
              color: root.bar.foreground
              opacity: 0.45
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
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
            visible: root.gpuPresent || root.ramPresent || root.totalPresent
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
            Text {
              text: "Total"
              color: sessionTable.mutedForeground
              font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall
              font.bold: true
              width: sessionTable.valueWidth
              visible: root.totalPresent
            }
          }

          Repeater {
            model: [
              { label: "Min", cpu: root.minWatts < 0 ? "—" : root.minWatts.toFixed(1) + " W",
                gpu: root.gpuMinWatts < 0 ? "—" : root.gpuMinWatts.toFixed(1) + " W",
                ram: root.ramMinWatts < 0 ? "—" : root.ramMinWatts.toFixed(1) + " W",
                total: root.totalMinWatts < 0 ? "—" : root.totalMinWatts.toFixed(1) + " W" },
              { label: "Avg", cpu: root.sampleCount === 0 ? "—" : root.avgWatts.toFixed(1) + " W",
                gpu: root.gpuSampleCount === 0 ? "—" : root.gpuAvgWatts.toFixed(1) + " W",
                ram: root.ramSampleCount === 0 ? "—" : root.ramAvgWatts.toFixed(1) + " W",
                total: root.totalSampleCount === 0 ? "—" : root.totalAvgWatts.toFixed(1) + " W" },
              { label: "Max", cpu: root.maxWatts < 0 ? "—" : root.maxWatts.toFixed(1) + " W",
                gpu: root.gpuMaxWatts < 0 ? "—" : root.gpuMaxWatts.toFixed(1) + " W",
                ram: root.ramMaxWatts < 0 ? "—" : root.ramMaxWatts.toFixed(1) + " W",
                total: root.totalMaxWatts < 0 ? "—" : root.totalMaxWatts.toFixed(1) + " W" }
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
              Text {
                text: sessionRow.modelData.total
                color: root.bar.foreground
                font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall
                width: sessionTable.valueWidth
                visible: root.totalPresent
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
              // nvidia-smi reports one; the iMac's Radeon has none to show.
              { label: "GPU cap", value: root.gpuLimitWatts.toFixed(0) + " W", shown: root.gpuPresent && root.gpuLimitWatts > 0 },
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
