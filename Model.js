// Pure model math for Punch: durations, quick-input parsing, fuzzy ranking,
// and day/week aggregation. Qt-free on purpose so `test/model-test.js` can
// run the whole thing under node; the QML owns colors, files, and clocks.

var SECONDS_PER_DAY = 86400

function isPlainObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

function pad2(n) {
  var v = Math.floor(Math.abs(n))
  return v < 10 ? "0" + v : String(v)
}

// ---------------------------------------------------------------- calendar

// Day boundaries go through Date so they land on local midnight, and day
// arithmetic goes through setDate so a DST change costs 23 or 25 hours
// rather than silently shifting every later boundary by an hour.
function dayStart(epochSeconds) {
  var d = new Date(epochSeconds * 1000)
  d.setHours(0, 0, 0, 0)
  return Math.floor(d.getTime() / 1000)
}

function addDays(epochSeconds, days) {
  var d = new Date(epochSeconds * 1000)
  d.setDate(d.getDate() + days)
  return Math.floor(d.getTime() / 1000)
}

function dayEnd(epochSeconds) {
  return dayStart(addDays(dayStart(epochSeconds), 1))
}

// ISO weeks start on Monday.
function weekStart(epochSeconds) {
  var start = dayStart(epochSeconds)
  var weekday = (new Date(start * 1000).getDay() + 6) % 7
  return dayStart(addDays(start, -weekday))
}

function isoDate(epochSeconds) {
  var d = new Date(epochSeconds * 1000)
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
}

function clockTime(epochSeconds) {
  var d = new Date(epochSeconds * 1000)
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

// ---------------------------------------------------------------- durations

// h:mm — what the bar pill and every total show. Hours are never truncated
// to two digits: a forgotten timer reading 31:07 should look wrong.
function clockDuration(seconds) {
  var s = Math.max(0, Math.floor(seconds))
  return Math.floor(s / 3600) + ":" + pad2(Math.floor((s % 3600) / 60))
}

// h:mm:ss for the panel hero, where the ticking second is the whole point.
function preciseDuration(seconds) {
  var s = Math.max(0, Math.floor(seconds))
  return Math.floor(s / 3600) + ":" + pad2(Math.floor((s % 3600) / 60)) + ":" + pad2(s % 60)
}

function humanDuration(seconds) {
  var s = Math.max(0, Math.floor(seconds))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  if (h > 0) return m > 0 ? h + "h " + m + "m" : h + "h"
  if (m > 0) return m + "m"
  return s + "s"
}

// Rounding is applied when an entry is stopped, never to the live timer:
// what you see running is real time, what lands in the log is billable time.
function roundedEnd(start, end, roundToMinutes) {
  var step = Math.max(0, Math.floor(roundToMinutes)) * 60
  if (step <= 0) return end
  var duration = Math.max(1, end - start)
  return start + Math.ceil(duration / step) * step
}

// ---------------------------------------------------------------- entries

function hashString(value) {
  var h = 2166136261
  var s = String(value || "")
  for (var i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i)
    h = (h * 16777619) >>> 0
  }
  return h >>> 0
}

function newId(startSeconds, project, salt) {
  return Math.floor(startSeconds).toString(36) + "-" + hashString(project + "|" + salt).toString(36)
}

// What a successful push to an external tracker left behind. An entry that
// carries one is done; an entry that does not is still owed. `skipped` is a
// settled outcome too — an entry the other side can never represent must
// stop asking to be sent, or it queues forever.
function sanitizeSync(raw) {
  if (!isPlainObject(raw)) return null
  var id = String(raw.id || "")
  var skipped = raw.skipped === true
  if (!id && !skipped) return null
  var out = { syncedAt: Math.floor(Number(raw.syncedAt)) || 0 }
  if (id) out.id = id
  if (skipped) out.skipped = true
  if (raw.reason) out.reason = String(raw.reason)
  return out
}

function sanitizeEntry(raw) {
  if (!isPlainObject(raw)) return null
  var start = Math.floor(Number(raw.start))
  var end = Math.floor(Number(raw.end))
  var project = String(raw.project || "").trim()
  if (!project || !isFinite(start) || !isFinite(end) || end <= start) return null
  var out = {
    id: String(raw.id || newId(start, project, end)),
    project: project,
    note: String(raw.note || ""),
    start: start,
    end: end
  }
  var sync = sanitizeSync(raw.moneybird)
  if (sync) out.moneybird = sync
  return out
}

// The single way to rewrite an entry. Editing one used to rebuild it field by
// field, which quietly dropped the sync marker and made an already-booked
// entry look owed again — so the next push sent a duplicate to Moneybird.
// Changing an entry must never change whether it has been sent.
function editedEntry(entry, changes) {
  var out = {
    id: entry.id,
    project: entry.project,
    note: entry.note,
    start: entry.start,
    end: entry.end
  }
  for (var key in (changes || {})) out[key] = changes[key]
  if (entry.moneybird) out.moneybird = entry.moneybird
  return out
}

function isSynced(entry) {
  return !!(entry && entry.moneybird)
}

function unsyncedEntries(entries) {
  var out = []
  for (var i = 0; i < entries.length; i++) {
    if (!isSynced(entries[i])) out.push(entries[i])
  }
  return out
}

// Only the fields the pusher needs. Keeping the payload narrow means a change
// to how entries are stored does not silently change what leaves the machine.
function syncPayload(entries) {
  var out = []
  for (var i = 0; i < entries.length; i++) {
    out.push({
      id: entries[i].id,
      project: entries[i].project,
      note: entries[i].note,
      start: entries[i].start,
      end: entries[i].end
    })
  }
  return out
}

// Fold the pusher's per-entry results back into the log. A result without an
// id and without `skipped` is a failure: it records nothing, so the entry
// stays owed and the next run picks it up again.
function applySyncResults(entries, results, atSeconds) {
  var byId = {}
  for (var r = 0; r < (results || []).length; r++) {
    var result = results[r]
    if (isPlainObject(result) && result.id) byId[String(result.id)] = result
  }
  var out = []
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i]
    var hit = byId[entry.id]
    if (!hit || (!hit.moneybirdId && hit.skipped !== true)) {
      out.push(entry)
      continue
    }
    var copy = {
      id: entry.id, project: entry.project, note: entry.note,
      start: entry.start, end: entry.end
    }
    copy.moneybird = sanitizeSync({
      id: hit.moneybirdId || "",
      skipped: hit.skipped === true,
      reason: hit.skipped === true ? (hit.error || "") : "",
      syncedAt: atSeconds
    })
    if (!copy.moneybird) delete copy.moneybird
    out.push(copy)
  }
  return out
}

function syncErrors(results) {
  var out = []
  for (var i = 0; i < (results || []).length; i++) {
    var result = results[i]
    if (isPlainObject(result) && result.error && result.skipped !== true) out.push(result.error)
  }
  return out
}

function parseEntries(text) {
  var lines = String(text || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    try {
      var entry = sanitizeEntry(JSON.parse(line))
      if (entry) out.push(entry)
    } catch (e) {
      // One unreadable line must not cost the user the rest of the log.
    }
  }
  out.sort(function(a, b) { return a.start - b.start })
  return out
}

function serializeEntries(entries) {
  var out = []
  for (var i = 0; i < entries.length; i++) out.push(JSON.stringify(entries[i]))
  return out.length ? out.join("\n") + "\n" : ""
}

function entrySeconds(entry) {
  return Math.max(0, entry.end - entry.start)
}

// An entry that spans midnight belongs to both days, clipped. Otherwise a
// session that ran past 00:00 would vanish from today's panel entirely.
function clipToRange(entry, from, to) {
  var start = Math.max(entry.start, from)
  var end = Math.min(entry.end, to)
  if (end <= start) return null
  var copy = { id: entry.id, project: entry.project, note: entry.note, start: start, end: end }
  copy.clipped = start !== entry.start || end !== entry.end
  // Carried through so the panel can mark what is already booked elsewhere.
  if (entry.moneybird) copy.moneybird = entry.moneybird
  return copy
}

function entriesInRange(entries, from, to) {
  var out = []
  for (var i = 0; i < entries.length; i++) {
    var clipped = clipToRange(entries[i], from, to)
    if (clipped) out.push(clipped)
  }
  out.sort(function(a, b) { return a.start - b.start })
  return out
}

function totalSeconds(entries) {
  var total = 0
  for (var i = 0; i < entries.length; i++) total += entrySeconds(entries[i])
  return total
}

function byProject(entries) {
  var totals = {}
  var order = []
  for (var i = 0; i < entries.length; i++) {
    var name = entries[i].project
    if (totals[name] === undefined) { totals[name] = 0; order.push(name) }
    totals[name] += entrySeconds(entries[i])
  }
  var out = []
  for (var j = 0; j < order.length; j++) out.push({ project: order[j], seconds: totals[order[j]] })
  out.sort(function(a, b) { return b.seconds - a.seconds || (a.project < b.project ? -1 : 1) })
  return out
}

// Seven day totals starting at `weekStartSeconds`, for the panel's week row.
function weekTotals(entries, weekStartSeconds) {
  var out = []
  for (var i = 0; i < 7; i++) {
    var from = dayStart(addDays(weekStartSeconds, i))
    var to = dayEnd(from)
    out.push({ start: from, seconds: totalSeconds(entriesInRange(entries, from, to)) })
  }
  return out
}

// Horizontal window for the day strip. A working day is assumed to run
// 08:00-18:00 and grows from there to cover whatever actually happened, so
// the strip is comparable day to day instead of rescaling on every entry.
function dayWindow(entries, dayStartSeconds, nowSeconds) {
  var from = dayStartSeconds + 8 * 3600
  var to = dayStartSeconds + 18 * 3600
  for (var i = 0; i < entries.length; i++) {
    from = Math.min(from, entries[i].start)
    to = Math.max(to, entries[i].end)
  }
  if (nowSeconds >= dayStartSeconds && nowSeconds < dayEnd(dayStartSeconds)) to = Math.max(to, nowSeconds)
  if (to - from < 3600) to = from + 3600
  return { from: from, to: to }
}

// ---------------------------------------------------------------- projects

// Deterministic hue per project name, as a 0..1 fraction the QML feeds to
// Qt.hsla. Hashing rather than assigning by index keeps a project the same
// color for its whole life, including after other projects come and go.
function projectHue(name) {
  return (hashString(String(name || "").toLowerCase()) % 360) / 360
}

function sanitizeProject(raw) {
  if (!isPlainObject(raw)) return null
  var name = String(raw.name || "").trim()
  if (!name) return null
  var lastUsed = Math.floor(Number(raw.lastUsed))
  return { name: name, lastUsed: isFinite(lastUsed) ? lastUsed : 0 }
}

function findProject(projects, name) {
  var key = String(name || "").trim().toLowerCase()
  for (var i = 0; i < projects.length; i++) {
    if (projects[i].name.toLowerCase() === key) return projects[i]
  }
  return null
}

function touchProject(projects, name, atSeconds) {
  var next = []
  var key = String(name || "").trim()
  var seen = false
  for (var i = 0; i < projects.length; i++) {
    if (projects[i].name.toLowerCase() === key.toLowerCase()) {
      next.push({ name: projects[i].name, lastUsed: atSeconds })
      seen = true
    } else {
      next.push({ name: projects[i].name, lastUsed: projects[i].lastUsed })
    }
  }
  if (!seen && key) next.push({ name: key, lastUsed: atSeconds })
  next.sort(function(a, b) { return b.lastUsed - a.lastUsed })
  return next
}

// Subsequence match. Word starts score triple and adjacent hits score a
// bonus, so "ab" ranks "acme-bar" over "grab" the way a launcher should.
function fuzzyScore(query, candidate) {
  var q = String(query || "").toLowerCase()
  var c = String(candidate || "").toLowerCase()
  if (!q) return 1
  var score = 0
  var cursor = 0
  var previous = -2
  for (var qi = 0; qi < q.length; qi++) {
    var ch = q.charAt(qi)
    var found = -1
    for (var k = cursor; k < c.length; k++) {
      if (c.charAt(k) === ch) { found = k; break }
    }
    if (found === -1) return -1
    score += (found === 0 || /[\s\-_.\/]/.test(c.charAt(found - 1))) ? 12 : 4
    if (found === previous + 1) score += 6
    previous = found
    cursor = found + 1
  }
  return score - Math.max(0, c.length - q.length) * 0.15
}

// Recency wins on an empty query; relevance wins once you type.
function rankProjects(projects, query) {
  var q = String(query || "").trim()
  var scored = []
  for (var i = 0; i < projects.length; i++) {
    var score = fuzzyScore(q, projects[i].name)
    if (score < 0) continue
    scored.push({ name: projects[i].name, lastUsed: projects[i].lastUsed, score: score })
  }
  scored.sort(function(a, b) {
    if (!q) return b.lastUsed - a.lastUsed
    return b.score - a.score || b.lastUsed - a.lastUsed
  })
  return scored
}

// ---------------------------------------------------------------- input

// The quick switcher's whole grammar:
//   acme                        start acme now
//   acme: pairing on the bar    start acme with a note
//   acme +45                    start acme as if it began 45 minutes ago
//   acme +45: writing the spec  both
// `+45` rather than a bare `45` so a project legitimately named "sprint 45"
// stays typeable.
function parseQuickInput(text) {
  var raw = String(text || "").trim()
  var note = ""
  var colon = raw.indexOf(":")
  if (colon !== -1) {
    note = raw.slice(colon + 1).trim()
    raw = raw.slice(0, colon).trim()
  }
  var backdate = 0
  var match = raw.match(/\s*\+(\d{1,4})$/)
  if (match) {
    backdate = parseInt(match[1], 10)
    raw = raw.slice(0, raw.length - match[0].length).trim()
  }
  return { project: raw, note: note, backdateMinutes: backdate }
}

// ---------------------------------------------------------------- export

function csvField(value) {
  var s = String(value === undefined || value === null ? "" : value)
  return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s
}

function toCsv(entries) {
  var rows = ["date,start,end,project,note,seconds,hours"]
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    var seconds = entrySeconds(e)
    rows.push([
      csvField(isoDate(e.start)),
      csvField(clockTime(e.start)),
      csvField(clockTime(e.end)),
      csvField(e.project),
      csvField(e.note),
      String(seconds),
      (seconds / 3600).toFixed(2)
    ].join(","))
  }
  return rows.join("\n") + "\n"
}

// One line for `punch` with no arguments, and for scripts and status bars
// that just want to know whether the clock is running.
function statusLine(running, elapsedSeconds) {
  if (!running) return "stopped"
  var note = running.note ? " (" + running.note + ")" : ""
  return running.project + " " + clockDuration(elapsedSeconds) + note
}

function summaryLines(entries, label) {
  var totals = byProject(entries)
  var lines = []
  for (var i = 0; i < totals.length; i++) {
    lines.push(rightPad(totals[i].project, 24) + clockDuration(totals[i].seconds))
  }
  lines.push(rightPad(label, 24) + clockDuration(totalSeconds(entries)))
  return lines
}

function rightPad(value, width) {
  var s = String(value || "")
  while (s.length < width) s += " "
  return s
}

if (typeof module !== "undefined") {
  module.exports = {
    dayStart: dayStart,
    addDays: addDays,
    dayEnd: dayEnd,
    weekStart: weekStart,
    isoDate: isoDate,
    clockTime: clockTime,
    clockDuration: clockDuration,
    preciseDuration: preciseDuration,
    humanDuration: humanDuration,
    roundedEnd: roundedEnd,
    hashString: hashString,
    newId: newId,
    sanitizeSync: sanitizeSync,
    sanitizeEntry: sanitizeEntry,
    editedEntry: editedEntry,
    isSynced: isSynced,
    unsyncedEntries: unsyncedEntries,
    syncPayload: syncPayload,
    applySyncResults: applySyncResults,
    syncErrors: syncErrors,
    parseEntries: parseEntries,
    serializeEntries: serializeEntries,
    entrySeconds: entrySeconds,
    clipToRange: clipToRange,
    entriesInRange: entriesInRange,
    totalSeconds: totalSeconds,
    byProject: byProject,
    weekTotals: weekTotals,
    dayWindow: dayWindow,
    projectHue: projectHue,
    sanitizeProject: sanitizeProject,
    findProject: findProject,
    touchProject: touchProject,
    fuzzyScore: fuzzyScore,
    rankProjects: rankProjects,
    parseQuickInput: parseQuickInput,
    csvField: csvField,
    toCsv: toCsv,
    statusLine: statusLine,
    summaryLines: summaryLines,
    rightPad: rightPad
  }
}
