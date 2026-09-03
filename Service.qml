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

  // The helpers live next to this file and are always run by absolute path,
  // never looked up on PATH. The host stamps the source directory into the
  // manifest; the resolved URL of this component is the same directory and
  // covers a host that does not.
  readonly property string sourceDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : localDir()
  readonly property string cliPath: sourceDir + "/bin/punch"
  readonly property string storeHelper: sourceDir + "/bin/punch-store"
  readonly property string syncHelper: sourceDir + "/bin/punch-moneybird"

  function localDir() {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return url.replace(/\/+$/, "")
  }

  // { project, note, start } while the clock runs, null otherwise.
  property var running: null
  property var projects: []
  property var entries: []
  // True once both files have been read from a healthy store. Nothing is
  // written before that, and nothing is written after a read fails: the
  // alternative is replacing a log we could not read with an empty one.
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
  //
  // Every string that arrives here — from the switcher, the panel, the CLI,
  // or anything else on the IPC target — goes through Model.cleanText and
  // the LIMITS it enforces before it is kept, and every number is clamped.
  // The model is the only place a bound is defined; this is where it is
  // applied to input.

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
    var name = Model.cleanText(projectName, Model.LIMITS.projectChars) || lastProject
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

    var backdate = Model.clampMinutes(backdateMinutes, Model.LIMITS.backdateMinutes) * 60
    var startAt = Math.max(at - backdate, earliestStart(), 0)
    if (startAt > at) startAt = at

    running = { project: name, note: Model.cleanText(note, Model.LIMITS.noteChars), start: startAt }
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
    entries = Model.appendEntry(entries, entry)
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
    var away = Model.clampMinutes(minutes, Model.LIMITS.backdateMinutes) * 60
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
    var note = Model.cleanText(text, Model.LIMITS.noteChars)
    if (note === running.note) return note ? note : "no note"
    running = { project: running.project, note: note, start: running.start }
    persistState()
    changed()
    return note ? running.project + ": " + note : "note cleared"
  }

  function switchTo(projectName) {
    var name = Model.cleanText(projectName, Model.LIMITS.projectChars)
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
    var key = Model.cleanText(id, 64)
    for (var i = 0; i < entries.length; i++) if (entries[i].id === key) return i
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
    var delta = Math.floor(Number(deltaMinutes)) || 0
    delta = Math.max(-Model.LIMITS.adjustMinutes, Math.min(Model.LIMITS.adjustMinutes, delta)) * 60
    var next = entries.slice()
    var entry = next[index]
    var end = Math.max(entry.start + 60, Math.min(entry.end + delta, entry.start + Model.LIMITS.spanSeconds))
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
    var note = Model.cleanText(text, Model.LIMITS.noteChars)
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
    var name = Model.cleanText(projectName, Model.LIMITS.projectChars)
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
    var text = Model.cleanText(sinceText, 32)
    if (text) {
      var parsed = Date.parse(text.length === 10 ? text + "T00:00:00" : text)
      if (!isNaN(parsed)) from = Math.floor(parsed / 1000)
    }
    return Model.toCsv(Model.entriesInRange(entries, from, nowSec + 1))
  }

  // ------------------------------------------------------------- persistence
  //
  // Nothing in here touches the disk by pathname. bin/punch-store opens the
  // data directory without following links, checks that it is ours and
  // private, and reads or publishes each file relative to that held
  // descriptor: a write lands in a fresh O_EXCL temp file, is fsynced, and
  // is renamed into place, so state.json and entries.jsonl are always either
  // the old text or the complete new text, and a link left at either name is
  // replaced rather than written through. The helper also refuses to read a
  // file over its byte ceiling, so a text never reaches this side unbounded.
  //
  // The two FileViews further down never load anything (preload: false).
  // They are only the inotify hook that says a file changed under us, at
  // which point the helper reads it again — which is how an edit made with
  // a text editor is picked up.

  // The exact text we last sent, so a change event that is our own rename
  // landing is told apart from an edit made outside the shell.
  property string _ownState: ""
  property string _ownEntries: ""
  property string storeError: ""
  property bool storeProblemNotified: false

  property var readQueue: []
  property bool stateRead: false
  property bool entriesRead: false

  // Text queued for the next write of each file; null when nothing is
  // waiting. Writes are one at a time and the newest text wins, so a burst
  // of edits costs one helper run per file, not one per keystroke.
  property var pendingState: null
  property var pendingEntries: null
  property double lastWriteAt: 0

  function stateText() {
    return JSON.stringify({
      version: 1,
      running: running,
      projects: projects
    }, null, 2) + "\n"
  }

  function persistState() {
    queueWrite("state", stateText())
  }

  function persistEntries() {
    queueWrite("entries", Model.serializeEntries(entries))
  }

  function persistAll() {
    persistEntries()
    persistState()
  }

  function queueWrite(which, text) {
    if (!loaded) {
      // A store that failed to read is asked again on every action, so
      // fixing the directory brings persistence back without a reload.
      requestRead("state")
      requestRead("entries")
      return
    }
    if (which === "state") { _ownState = text; pendingState = text }
    else { _ownEntries = text; pendingEntries = text }
    pumpWrites()
  }

  // Entries go before state: the finished entry belongs on disk before the
  // running one that replaced it, or a crash in between double-bills.
  function pumpWrites() {
    if (storeWriter.running) return
    var which = pendingEntries !== null ? "entries" : (pendingState !== null ? "state" : "")
    if (!which) return
    var text = which === "entries" ? pendingEntries : pendingState
    if (which === "entries") pendingEntries = null
    else pendingState = null
    storeWriter.which = which
    storeWriter.payload = text
    storeWriter.stdinEnabled = true
    storeWriter.command = [storeHelper, "write", which, String(Model.utf8Length(text))]
    storeWriter.running = true
  }

  function finishWrite(which, exitCode, err) {
    lastWriteAt = Date.now()
    if (exitCode !== 0) reportStoreProblem(which, err || "punch-store write failed")
    else storeError = ""
    pumpWrites()
  }

  function requestRead(which) {
    if (readQueue.indexOf(which) === -1) {
      var next = readQueue.slice()
      next.push(which)
      readQueue = next
    }
    pumpReads()
  }

  function pumpReads() {
    if (storeReader.running || !readQueue.length) return
    var which = readQueue[0]
    readQueue = readQueue.slice(1)
    storeReader.which = which
    storeReader.command = [storeHelper, "read", which]
    storeReader.running = true
  }

  function finishRead(which, exitCode, text, err) {
    if (exitCode !== 0) {
      reportStoreProblem(which, err || "punch-store read failed")
      if (loaded) loaded = false
      pumpReads()
      return
    }
    storeError = ""
    storeProblemNotified = false
    if (which === "state") {
      if (text !== _ownState) applyState(text)
      stateRead = true
    } else {
      if (text !== _ownEntries) applyEntries(text)
      entriesRead = true
    }
    if (!loaded && stateRead && entriesRead) loaded = true
    pumpReads()
  }

  // A change event that arrives while our own write is pending, in flight,
  // or just landed is our own rename. Anything else is worth a read.
  function fileChanged(which) {
    var ours = which === "state" ? pendingState !== null : pendingEntries !== null
    if (ours || storeWriter.running || Date.now() - lastWriteAt < 500) return
    requestRead(which)
  }

  function reportStoreProblem(which, message) {
    storeError = Model.cleanText(message, Model.LIMITS.syncErrorChars)
    console.warn("punch: " + which + ": " + storeError)
    if (storeProblemNotified) return
    storeProblemNotified = true
    Quickshell.execDetached([
      omarchyPath + "/bin/omarchy-notification-send",
      "-u", "critical",
      "-g", "󰥔",
      "Punch is not saving",
      storeError
    ])
  }

  function applyState(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "{}")) } catch (e) { parsed = null }
    if (!parsed || typeof parsed !== "object") parsed = {}
    projects = Model.sanitizeProjects(parsed.projects)
    running = Model.sanitizeRunning(parsed.running, now())
    changed()
  }

  function applyEntries(raw) {
    entries = Model.parseEntries(raw)
    changed()
  }

  Component.onCompleted: {
    requestRead("state")
    requestRead("entries")
  }

  Process {
    id: storeReader
    property string which: ""
    running: false
    command: []
    stdout: StdioCollector { id: storeReadOut; waitForEnd: true }
    stderr: StdioCollector { id: storeReadErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.finishRead(which, exitCode, storeReadOut.text, storeReadErr.text)
    }
  }

  Process {
    id: storeWriter
    property string which: ""
    property string payload: ""
    stdinEnabled: true
    running: false
    command: []
    onStarted: {
      write(payload)
      payload = ""
      // Closing stdin is what gives the helper its EOF. Doing it in the same
      // handler as the write closed the channel before the write flushed;
      // one turn of the event loop is enough. The helper checks the byte
      // count it was told against what arrived, so a short payload is
      // refused rather than published.
      Qt.callLater(function() { storeWriter.stdinEnabled = false })
    }
    stderr: StdioCollector { id: storeWriteErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.finishWrite(which, exitCode, storeWriteErr.text)
    }
  }

  FileView {
    path: root.stateRead ? root.statePath : ""
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: root.fileChanged("state")
  }

  FileView {
    path: root.entriesRead ? root.entriesPath : ""
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: root.fileChanged("entries")
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
  //
  // Entries are pushed to Moneybird by bin/punch-moneybird, a plain script
  // that shells out to the official moneybird-cli. Nothing about the network
  // lives in here: this half decides *when* to push and remembers what came
  // back, so a sync that goes wrong can still be run and read from a
  // terminal.
  //
  // The process contract, and what each part of it is for:
  //
  //   - One push carries at most LIMITS.syncBatch entries and answers with
  //     at most that many results. A backlog drains in rounds, so a run has
  //     a bounded runtime and a bounded answer.
  //   - The helper is started through `setsid --wait --fork`, so the process
  //     Quickshell holds is a thin parent and the helper is the leader of
  //     its own session. Quickshell kills that parent with SIGKILL when this
  //     component is destroyed; the helper notices it has been orphaned
  //     within half a second and tears down its own subprocess tree. That is
  //     what makes a shell reload mid-push leave no moneybird-cli behind.
  //   - Cancellation (the watchdog, or sync being switched off) is SIGTERM to
  //     the parent, which the helper treats the same way, followed by SIGKILL
  //     five seconds later if the parent has not gone. Every moneybird-cli
  //     call inside the helper has its own deadline, and the run as a whole
  //     has a budget, so the watchdog is the last fence, not the first.
  //   - A cancelled or timed-out run records nothing, however far it got.
  //     The helper's answer is only trusted from a run that exited on its
  //     own, and only when it is the bounded JSON array the contract
  //     promises; anything larger or stranger is a failure, not data.
  //   - A run never starts while one is in flight. Restarting is: cancel,
  //     wait for the exit, run again.

  readonly property var unsynced: Model.unsyncedEntries(entries)
  readonly property int pendingSync: unsynced.length

  property bool syncing: false
  property string lastSyncError: ""
  property int lastSyncAt: 0
  property int syncFailures: 0
  property bool syncProblemNotified: false
  property string syncCancelReason: ""

  function scheduleSync() {
    if (!syncEnabled) return
    syncDebounce.restart()
  }

  function runSync() {
    if (!syncEnabled) return "moneybird sync is off"
    if (!loaded) return "not ready"
    if (syncing || syncProcess.running) return "already syncing"
    var payload = Model.syncPayload(unsynced)
    if (!payload.length) return "nothing to sync"

    syncing = true
    syncCancelReason = ""
    // Clear the old failure as the new attempt starts, or `punch sync status`
    // reports a stale reason while a run is still in flight.
    lastSyncError = ""
    syncRetry.stop()
    syncKill.stop()
    syncWatchdog.restart()
    syncProcess.payload = JSON.stringify(payload)
    // Quickshell closes stdin at start when this is false, and it is left
    // false by the previous run, so a push after the first would otherwise
    // hand the helper an empty payload.
    syncProcess.stdinEnabled = true
    syncProcess.command = ["setsid", "--wait", "--fork", syncHelper, "push"]
    syncProcess.running = true
    return "pushing " + payload.length + (payload.length === 1 ? " entry" : " entries")
  }

  function cancelSync(reason) {
    if (!syncProcess.running) return
    syncCancelReason = reason
    syncProcess.signal(15)
    syncKill.restart()
  }

  onSyncEnabledChanged: if (!syncEnabled) cancelSync("moneybird sync was switched off")

  Component.onDestruction: {
    // Quickshell follows this with SIGKILL on the parent; the helper handles
    // either by tearing down its own tree.
    if (syncProcess.running) syncProcess.signal(15)
  }

  function applySyncRun(exitCode, out, err) {
    syncing = false
    syncWatchdog.stop()
    syncKill.stop()

    var cancelReason = syncCancelReason
    var cancelled = cancelReason !== ""
    syncCancelReason = ""
    var results = cancelled ? null : Model.parseSyncResults(out)

    // Whatever did land is recorded even when the run as a whole failed, so a
    // partial push is never repeated against the entries that got through.
    if (results && results.length) {
      entries = Model.applySyncResults(entries, results, now())
      persistEntries()
      changed()
    }

    var failed = exitCode !== 0 || cancelled
    if (!failed && results === null) {
      failed = true
      err = "punch-moneybird gave an answer that is not the bounded result list it promises"
    }
    var perEntry = results ? Model.syncErrors(results) : []
    if (failed) {
      lastSyncError = Model.cleanText(cancelled ? cancelReason : (err || out || "moneybird sync failed"), Model.LIMITS.syncErrorChars)
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

  // The outer deadline. A push that never comes back would otherwise leave
  // syncing stuck true and no further attempt ever scheduled.
  Timer {
    id: syncWatchdog
    interval: 120000
    repeat: false
    onTriggered: root.cancelSync("the Moneybird push did not finish within two minutes")
  }

  // A parent that ignored SIGTERM gets SIGKILL; the helper cleans up after
  // either.
  Timer {
    id: syncKill
    interval: 5000
    repeat: false
    onTriggered: if (syncProcess.running) syncProcess.signal(9)
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
      // Closing stdin is what gives the child its EOF, and there is no
      // closeStdin in this Quickshell — dropping stdinEnabled is the only
      // lever. Doing it in the same handler as the write closed the channel
      // before the write flushed, so the helper sat on stdin forever and the
      // sync never came back. One turn of the event loop is enough.
      Qt.callLater(function() { syncProcess.stdinEnabled = false })
    }
    stdout: StdioCollector { id: syncStdout; waitForEnd: true }
    stderr: StdioCollector { id: syncStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.applySyncRun(exitCode, syncStdout.text, syncStderr.text)
    }
  }

  // ------------------------------------------------------------- ipc

  // One target for the CLI and for anything else that wants to drive the
  // clock — a hook, a keybind, an agent. Every method answers in one line,
  // and every argument is bounded before it is used (see the actions above).
  IpcHandler {
    target: "punch"

    function status(): string {
      var line = Model.statusLine(root.running, root.elapsed)
      return root.storeError ? line + " [not saving: " + root.storeError + "]" : line
    }
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
