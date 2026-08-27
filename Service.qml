import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Model.js" as Model

// The clock itself. One instance per shell session, mounted by the host's
// service loader, so the running entry survives a panel closing, a bar
// reload, or a second monitor appearing. Everything else in this plugin —
// the bar pill, the day panel, the quick switcher, the CLI — is a view onto
// this object.
Item {
  id: root

  // Injected by the omarchy-shell service loader.
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string home: Quickshell.env("HOME")
  readonly property string dataDir: (Quickshell.env("XDG_DATA_HOME") || (home + "/.local/share")) + "/punch"
  readonly property string statePath: dataDir + "/state.json"
  readonly property string entriesPath: dataDir + "/entries.jsonl"
  readonly property string sourceDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
  readonly property string cliPath: sourceDir ? sourceDir + "/bin/punch" : "punch"

  // { project, note, start } while the clock runs, null otherwise.
  property var running: null
  property var projects: []
  property var entries: []
  property bool loaded: false

  // Ticks every second while running so the pill and hero stay live, and
  // once a minute otherwise so "today" rolls over at midnight on its own.
  property int nowSec: Math.floor(Date.now() / 1000)

  readonly property int elapsed: running ? Math.max(0, nowSec - running.start) : 0
  readonly property string project: running ? String(running.project) : ""
  readonly property string lastProject: projects.length ? String(projects[0].name) : ""

  readonly property int todayStart: Model.dayStart(nowSec)
  readonly property var todayEntries: Model.entriesInRange(entries, todayStart, Model.dayEnd(todayStart))
  // The running entry counts toward today the moment it starts. A total that
  // only moves when you stop is a total nobody trusts.
  readonly property int todaySeconds: Model.totalSeconds(todayEntries)
    + (running ? Math.max(0, nowSec - Math.max(running.start, todayStart)) : 0)
  readonly property int weekStart: Model.weekStart(nowSec)
  readonly property int weekSeconds: Model.totalSeconds(Model.entriesInRange(entries, weekStart, Model.dayEnd(nowSec)))
    + (running ? Math.max(0, nowSec - Math.max(running.start, weekStart)) : 0)

  signal changed()

  // ------------------------------------------------------------- settings

  // Services are not handed the widget's inline settings, so read them off
  // the shell config directly. That also means the settings apply even when
  // the pill has been taken off the bar and only the CLI is driving.
  readonly property var settings: {
    var config = shell && shell.shellConfig ? shell.shellConfig : null
    if (!config) return ({})
    var id = manifest && manifest.id ? String(manifest.id) : "pb.punch"
    var sections = ["left", "center", "right"]
    if (config.bar && config.bar.layout) {
      for (var s = 0; s < sections.length; s++) {
        var list = config.bar.layout[sections[s]]
        if (!Array.isArray(list)) continue
        for (var i = 0; i < list.length; i++) {
          if (list[i] && String(list[i].id) === id) return list[i]
        }
      }
    }
    if (Array.isArray(config.plugins)) {
      for (var p = 0; p < config.plugins.length; p++) {
        if (config.plugins[p] && String(config.plugins[p].id) === id) return config.plugins[p]
      }
    }
    return ({})
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  readonly property int idleThresholdSec: intSetting("idleThresholdSec", 900, 0, 7200)
  readonly property int roundToMinutes: intSetting("roundToMinutes", 0, 0, 60)
  readonly property bool syncEnabled: setting("moneybirdSync", false) === true

  // ------------------------------------------------------------- live views

  // Bar widgets mount once per monitor and are rebuilt on every reload, so
  // they announce themselves here rather than the service hunting for them.
  property var widgets: []

  function registerWidget(widget) {
    if (!widget || widgets.indexOf(widget) !== -1) return
    var next = widgets.slice()
    next.push(widget)
    widgets = next
  }

  function unregisterWidget(widget) {
    var next = []
    for (var i = 0; i < widgets.length; i++) if (widgets[i] !== widget) next.push(widgets[i])
    widgets = next
  }

  // The bar already knows which of its per-monitor copies of a widget the
  // focused output owns, including the zero-size placeholder an anchored
  // center module leaves behind. Ask it rather than opening whichever
  // instance happened to register first, which put the panel on the laptop
  // display while you were working on another screen.
  function openPanel() {
    var id = manifest && manifest.id ? String(manifest.id) : "pb.punch"
    if (shell && shell.bar && typeof shell.bar.summonBarWidget === "function"
        && shell.bar.summonBarWidget(id) === true) return true

    // Fallback for a replacement bar that does not offer the router.
    for (var i = 0; i < widgets.length; i++) {
      if (widgets[i] && typeof widgets[i].open === "function" && widgets[i].visible !== false) {
        widgets[i].open()
        return true
      }
    }
    return false
  }

  function openQuickSwitch() {
    if (!shell || typeof shell.summon !== "function") return false
    return shell.summon(manifest && manifest.id ? manifest.id : "pb.punch", "{}") === true
  }

  // ------------------------------------------------------------- actions

  function now() {
    return Math.floor(Date.now() / 1000)
  }

  // The last logged end is a floor for any new start: backdating past it
  // would silently double-bill the overlap.
  function earliestStart() {
    var floorAt = 0
    for (var i = 0; i < entries.length; i++) floorAt = Math.max(floorAt, entries[i].end)
    return floorAt
  }

  function start(projectName, note, backdateMinutes) {
    var name = String(projectName || "").trim() || lastProject
    if (!name) return "no project"

    var at = now()
    // Switching projects finishes an entry, and a finished entry belongs on
    // disk before anything else happens — persisting only the running state
    // here left the one we just closed alive in memory alone.
    var closed = false
    if (running) {
      if (running.project.toLowerCase() === name.toLowerCase()) return "already running"
      closed = stopAt(at) !== null
    }

    var backdate = Math.max(0, Math.floor(Number(backdateMinutes) || 0)) * 60
    var startAt = Math.max(at - backdate, earliestStart(), 0)
    if (startAt > at) startAt = at

    running = { project: name, note: String(note || ""), start: startAt }
    projects = Model.touchProject(projects, name, at)
    if (closed) { persistEntries(); scheduleSync() }
    persistState()
    changed()

    var line = Model.statusLine(running, at - startAt)
    // Say so when the overlap guard ate the backdate, rather than reporting
    // a start time that quietly is not the one that was asked for.
    if (backdate > 0 && startAt > at - backdate) line += " (backdate clipped to the last entry)"
    return line
  }

  function startInput(text) {
    var parsed = Model.parseQuickInput(text)
    return start(parsed.project, parsed.note, parsed.backdateMinutes)
  }

  // Shared by stop() and by start() switching projects, so a switch never
  // leaves a gap between the entry that ended and the one that began.
  function stopAt(at) {
    if (!running) return null
    var end = Model.roundedEnd(running.start, at, roundToMinutes)
    var entry = Model.sanitizeEntry({
      id: Model.newId(running.start, running.project, at),
      project: running.project,
      note: running.note,
      start: running.start,
      end: end
    })
    running = null
    if (!entry) return null
    var next = entries.slice()
    next.push(entry)
    entries = next
    return entry
  }

  function stop() {
    if (!running) return "stopped"
    var was = running.project
    var entry = stopAt(now())
    persistAll()
    changed()
    scheduleSync()
    if (!entry) return "discarded " + was + " (under a second)"
    return was + " " + Model.clockDuration(Model.entrySeconds(entry))
  }

  function toggle() {
    return running ? stop() : start(lastProject, "", 0)
  }

  function discard() {
    if (!running) return "stopped"
    var was = running.project
    running = null
    persistState()
    changed()
    return "discarded " + was
  }

  // Cut the last `minutes` off the running entry and pick it straight back
  // up, which is what "I was away, do not bill that" actually means.
  function trim(minutes) {
    if (!running) return "stopped"
    var away = Math.max(0, Math.floor(Number(minutes) || 0)) * 60
    if (away <= 0) return "nothing to trim"

    var at = now()
    var cut = at - away
    var name = running.project
    var note = running.note
    if (cut <= running.start) {
      running = null
      persistState()
    } else {
      stopAt(cut)
      persistAll()
    }
    running = { project: name, note: note, start: at }
    persistState()
    changed()
    return "trimmed " + Model.humanDuration(away) + " from " + name
  }

  // The note is the description Moneybird may print on an invoice, so it has
  // to be writable while the work is still fresh — not only in the second the
  // clock starts, which is the one moment you have nothing to say yet.
  function setNote(text) {
    if (!running) return "stopped"
    var note = String(text || "").trim()
    if (note === running.note) return note ? note : "no note"
    running = { project: running.project, note: note, start: running.start }
    persistState()
    changed()
    return note ? running.project + ": " + note : "note cleared"
  }

  function switchTo(projectName) {
    var name = String(projectName || "").trim()
    if (!name) return "no project"
    return start(name, "", 0)
  }

  // Scroll on the pill walks the recent list without stopping the clock.
  function cycle(direction) {
    if (!projects.length) return "no projects"
    var current = running ? running.project.toLowerCase() : ""
    var index = -1
    for (var i = 0; i < projects.length; i++) {
      if (projects[i].name.toLowerCase() === current) { index = i; break }
    }
    var step = Number(direction) < 0 ? -1 : 1
    var next = (index + step + projects.length * 2) % projects.length
    if (index === -1) next = 0
    return switchTo(projects[next].name)
  }

  // ------------------------------------------------------------- editing

  function findEntry(id) {
    for (var i = 0; i < entries.length; i++) if (entries[i].id === String(id)) return i
    return -1
  }

  function deleteEntry(id) {
    var index = findEntry(id)
    if (index === -1) return "unknown entry"
    var removed = entries[index]
    var next = entries.slice()
    next.splice(index, 1)
    entries = next
    persistAll()
    changed()
    return "deleted " + removed.project
  }

  function adjustEntry(id, deltaMinutes) {
    var index = findEntry(id)
    if (index === -1) return "unknown entry"
    var delta = Math.floor(Number(deltaMinutes) || 0) * 60
    var next = entries.slice()
    var entry = next[index]
    var end = Math.max(entry.start + 60, entry.end + delta)
    next[index] = Model.editedEntry(entry, { end: end })
    entries = next
    persistAll()
    changed()
    return Model.clockDuration(end - entry.start)
  }

  // The note on an entry that is already finished. Same idea as setNote, one
  // step further back: the description is worth fixing when you remember what
  // the work was, not only while it is still running.
  function setEntryNote(id, text) {
    var index = findEntry(id)
    if (index === -1) return "unknown entry"
    var note = String(text || "").trim()
    var entry = entries[index]
    if (entry.note === note) return note || "no note"
    var next = entries.slice()
    next[index] = Model.editedEntry(entry, { note: note })
    entries = next
    persistAll()
    changed()
    return note ? entry.project + ": " + note : "note cleared"
  }

  function reassignEntry(id, projectName) {
    var index = findEntry(id)
    var name = String(projectName || "").trim()
    if (index === -1 || !name) return "unknown entry"
    var next = entries.slice()
    var entry = next[index]
    next[index] = Model.editedEntry(entry, { project: name })
    entries = next
    projects = Model.touchProject(projects, name, now())
    persistAll()
    changed()
    return "moved to " + name
  }

  // ------------------------------------------------------------- reporting

  function reportFor(from, to, label) {
    var scoped = Model.entriesInRange(entries, from, to)
    if (running) {
      var live = Model.clipToRange({ id: "running", project: running.project, note: running.note, start: running.start, end: nowSec }, from, to)
      if (live) scoped.push(live)
    }
    if (!scoped.length) return "nothing tracked"
    return Model.summaryLines(scoped, label).join("\n")
  }

  function todayReport() {
    return reportFor(todayStart, Model.dayEnd(todayStart), "TODAY")
  }

  function weekReport() {
    return reportFor(weekStart, Model.dayEnd(nowSec), "THIS WEEK")
  }

  function csvSince(sinceText) {
    var from = 0
    var text = String(sinceText || "").trim()
    if (text) {
      var parsed = Date.parse(text.length === 10 ? text + "T00:00:00" : text)
      if (!isNaN(parsed)) from = Math.floor(parsed / 1000)
    }
    return Model.toCsv(Model.entriesInRange(entries, from, nowSec + 1))
  }

  // ------------------------------------------------------------- persistence

  // FileView writes come straight back as a file change. Remembering the
  // exact text we wrote is what tells our own echo apart from a real edit
  // made outside the shell, which we do want to pick up.
  property string _ownState: ""
  property string _ownEntries: ""

  function stateText() {
    return JSON.stringify({
      version: 1,
      running: running,
      projects: projects
    }, null, 2) + "\n"
  }

  function persistState() {
    if (!loaded) return
    _ownState = stateText()
    stateFile.setText(_ownState)
  }

  function persistEntries() {
    if (!loaded) return
    _ownEntries = Model.serializeEntries(entries)
    entriesFile.setText(_ownEntries)
  }

  function persistAll() {
    persistEntries()
    persistState()
  }

  function applyState(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "{}")) } catch (e) { parsed = null }
    if (!parsed || typeof parsed !== "object") parsed = {}

    var list = Array.isArray(parsed.projects) ? parsed.projects : []
    var cleaned = []
    for (var i = 0; i < list.length; i++) {
      var project = Model.sanitizeProject(list[i])
      if (project) cleaned.push(project)
    }
    cleaned.sort(function(a, b) { return b.lastUsed - a.lastUsed })
    projects = cleaned

    var live = parsed.running
    if (live && String(live.project || "").trim() && isFinite(Number(live.start))) {
      running = { project: String(live.project).trim(), note: String(live.note || ""), start: Math.floor(Number(live.start)) }
    } else {
      running = null
    }
    changed()
  }

  function applyEntries(raw) {
    entries = Model.parseEntries(raw)
    changed()
  }

  Process {
    id: ensureDir
    command: ["mkdir", "-p", root.dataDir]
    running: true
    onExited: {
      root.loaded = true
      stateFile.reload()
      entriesFile.reload()
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: if (text() !== root._ownState) root.applyState(text())
    onLoadFailed: root.applyState("")
    onFileChanged: reload()
  }

  FileView {
    id: entriesFile
    path: root.entriesPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: if (text() !== root._ownEntries) root.applyEntries(text())
    onLoadFailed: root.applyEntries("")
    onFileChanged: reload()
  }

  Timer {
    interval: root.running ? 1000 : 60000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.nowSec = Math.floor(Date.now() / 1000)
  }

  // ------------------------------------------------------------- idle

  // Only ever asks; never edits the log behind your back. Coming back from
  // lunch with the clock still on acme is a judgement call, so the toast
  // makes trimming a single click and doing nothing the default.
  property int idleSince: 0

  IdleMonitor {
    id: idleMonitor
    enabled: root.running !== null && root.idleThresholdSec > 0
    timeout: root.idleThresholdSec
    respectInhibitors: true
    onIsIdleChanged: {
      if (isIdle) {
        root.idleSince = root.now() - root.idleThresholdSec
        return
      }
      if (!root.idleSince || !root.running) { root.idleSince = 0; return }
      var away = root.now() - root.idleSince
      root.idleSince = 0
      if (away < root.idleThresholdSec) return
      root.notifyIdle(Math.floor(away / 60))
    }
  }

  function notifyIdle(minutes) {
    if (!running || minutes <= 0) return
    Quickshell.execDetached([
      omarchyPath + "/bin/omarchy-notification-send",
      "-u", "normal",
      "-g", "󰥔",
      "Away " + Model.humanDuration(minutes * 60),
      "Still on " + running.project + ". Click to drop that time.",
      "--exec", cliPath, "trim", String(minutes)
    ])
  }

  // ------------------------------------------------------------- moneybird

  // Entries are pushed to Moneybird by bin/punch-moneybird, a plain script
  // that shells out to the official moneybird-cli. Nothing about the network
  // lives in here: this half decides *when* to push and remembers what came
  // back, so a sync that goes wrong can still be run and read from a
  // terminal.
  readonly property string syncHelper: sourceDir ? sourceDir + "/bin/punch-moneybird" : ""
  readonly property var unsynced: Model.unsyncedEntries(entries)
  readonly property int pendingSync: unsynced.length

  property bool syncing: false
  property string lastSyncError: ""
  property int lastSyncAt: 0
  property int syncFailures: 0
  property bool syncProblemNotified: false

  function scheduleSync() {
    if (!syncEnabled) return
    syncDebounce.restart()
  }

  function runSync() {
    if (!syncEnabled) return "moneybird sync is off"
    if (!loaded || !syncHelper) return "not ready"
    if (syncing) return "already syncing"
    var payload = Model.syncPayload(unsynced)
    if (!payload.length) return "nothing to sync"

    syncing = true
    syncRetry.stop()
    syncProcess.payload = JSON.stringify(payload)
    syncProcess.command = [syncHelper, "push"]
    syncProcess.running = true
    return "pushing " + payload.length + (payload.length === 1 ? " entry" : " entries")
  }

  function applySyncRun(exitCode, out, err) {
    syncing = false

    var results = null
    try { results = JSON.parse(String(out || "")) } catch (e) { results = null }

    // Whatever did land is recorded even when the run as a whole failed, so a
    // partial push is never repeated against the entries that got through.
    if (Array.isArray(results) && results.length) {
      entries = Model.applySyncResults(entries, results, now())
      persistEntries()
      changed()
    }

    var failed = exitCode !== 0
    var perEntry = Array.isArray(results) ? Model.syncErrors(results) : []
    if (failed) {
      lastSyncError = String(err || out || "moneybird sync failed").replace(/\s+/g, " ").trim().substring(0, 200)
    } else if (perEntry.length) {
      lastSyncError = perEntry[0]
    } else {
      lastSyncError = ""
    }

    if (lastSyncError) {
      syncFailures++
      // Back off 1, 2, 4 ... minutes so a token that needs re-issuing is not
      // retried into the ground, capped so it still recovers on its own.
      syncRetry.interval = Math.min(30 * 60000, 60000 * Math.pow(2, Math.min(5, syncFailures - 1)))
      syncRetry.restart()
      // One notification per run of bad luck, not one per attempt.
      if (syncFailures >= 3 && !syncProblemNotified) {
        syncProblemNotified = true
        notifySyncProblem()
      }
      return
    }

    syncFailures = 0
    syncProblemNotified = false
    lastSyncAt = now()
    // A run that cleared some but not all of the backlog goes again.
    if (pendingSync > 0) syncDebounce.restart()
  }

  function notifySyncProblem() {
    Quickshell.execDetached([
      omarchyPath + "/bin/omarchy-notification-send",
      "-u", "normal",
      "-g", "󰥔",
      pendingSync + (pendingSync === 1 ? " entry" : " entries") + " not in Moneybird",
      lastSyncError,
      "--exec", cliPath, "sync"
    ])
  }

  function syncStatus() {
    if (!syncEnabled) return "moneybird sync is off"
    var lines = [pendingSync + " waiting" + (syncing ? ", syncing now" : "")]
    if (lastSyncAt) lines.push("last synced " + Model.clockTime(lastSyncAt))
    if (lastSyncError) lines.push("last error: " + lastSyncError)
    return lines.join("\n")
  }

  Timer {
    id: syncDebounce
    interval: 3000
    repeat: false
    onTriggered: root.runSync()
  }

  Timer {
    id: syncRetry
    interval: 60000
    repeat: false
    onTriggered: root.runSync()
  }

  // Anything left over from a previous session goes out once the log is in.
  onLoadedChanged: if (loaded) scheduleSync()

  Process {
    id: syncProcess
    property string payload: ""
    stdinEnabled: true
    running: false
    command: []
    onStarted: {
      write(payload + "\n")
      payload = ""
      stdinEnabled = false
    }
    stdout: StdioCollector { id: syncStdout; waitForEnd: true }
    stderr: StdioCollector { id: syncStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.applySyncRun(exitCode, syncStdout.text, syncStderr.text)
    }
  }

  // ------------------------------------------------------------- ipc

  // One target for the CLI and for anything else that wants to drive the
  // clock — a hook, a keybind, an agent. Every method answers in one line.
  IpcHandler {
    target: "punch"

    function status(): string { return Model.statusLine(root.running, root.elapsed) }
    function start(input: string): string { return root.startInput(input) }
    function stop(): string { return root.stop() }
    function toggle(): string { return root.toggle() }
    function discard(): string { return root.discard() }
    function trim(minutes: string): string { return root.trim(minutes) }
    function next(): string { return root.cycle(1) }
    function previous(): string { return root.cycle(-1) }
    function today(): string { return root.todayReport() }
    function week(): string { return root.weekReport() }
    function csv(since: string): string { return root.csvSince(since) }
    function projects(): string {
      var names = []
      for (var i = 0; i < root.projects.length; i++) names.push(root.projects[i].name)
      return names.join("\n")
    }
    function note(text: string): string { return root.setNote(text) }
    function sync(): string { return root.runSync() }
    function syncstatus(): string { return root.syncStatus() }
    function pick(): string { return root.openQuickSwitch() ? "ok" : "no overlay" }
    function panel(): string { return root.openPanel() ? "ok" : "no bar widget" }
  }
}
