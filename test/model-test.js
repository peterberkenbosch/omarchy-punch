#!/usr/bin/env node
// Run with: node test/model-test.js
// Model.js is Qt-free so the arithmetic that decides what gets billed can be
// checked without a compositor.

var M = require("../Model.js")

var failures = 0

function check(label, actual, expected) {
  var a = JSON.stringify(actual)
  var e = JSON.stringify(expected)
  if (a === e) return
  failures++
  console.error("FAIL " + label + "\n  expected " + e + "\n  actual   " + a)
}

// Durations
check("clockDuration zero", M.clockDuration(0), "0:00")
check("clockDuration minutes", M.clockDuration(7 * 60), "0:07")
check("clockDuration hours", M.clockDuration(3600 + 24 * 60), "1:24")
check("clockDuration overnight", M.clockDuration(31 * 3600 + 7 * 60), "31:07")
check("preciseDuration", M.preciseDuration(3600 + 24 * 60 + 9), "1:24:09")
check("humanDuration hours", M.humanDuration(5400), "1h 30m")
check("humanDuration exact hour", M.humanDuration(3600), "1h")
check("humanDuration minutes", M.humanDuration(120), "2m")

// Rounding is off by default and always rounds up when on.
check("roundedEnd off", M.roundedEnd(0, 61, 0), 61)
check("roundedEnd quarter up", M.roundedEnd(0, 61, 15), 900)
check("roundedEnd exact stays", M.roundedEnd(0, 1800, 15), 1800)
check("roundedEnd second over", M.roundedEnd(0, 1801, 15), 2700)

// Entries
var day = M.dayStart(Math.floor(new Date(2026, 7, 26, 12, 0, 0).getTime() / 1000))
var entries = [
  { id: "a", project: "acme", note: "", start: day + 9 * 3600, end: day + 10 * 3600 },
  { id: "b", project: "beta", note: "spec", start: day + 10 * 3600, end: day + 11 * 3600 + 1800 },
  { id: "c", project: "acme", note: "", start: day + 13 * 3600, end: day + 14 * 3600 }
]
check("totalSeconds", M.totalSeconds(entries), 3.5 * 3600)
check("byProject ordering", M.byProject(entries).map(function(r) { return r.project }), ["acme", "beta"])
check("byProject totals", M.byProject(entries)[0].seconds, 2 * 3600)

// An entry running past midnight shows on both days, clipped, never doubled.
var overnight = [{ id: "n", project: "acme", note: "", start: day + 23 * 3600, end: day + 25 * 3600 }]
check("clip to today", M.totalSeconds(M.entriesInRange(overnight, day, M.dayEnd(day))), 3600)
var tomorrow = M.dayEnd(day)
check("clip to tomorrow", M.totalSeconds(M.entriesInRange(overnight, tomorrow, M.dayEnd(tomorrow))), 3600)

// Round-trip through the log format, including a corrupt line.
var text = M.serializeEntries(entries) + "{ not json\n"
check("parseEntries skips garbage", M.parseEntries(text).length, 3)
check("parseEntries preserves note", M.parseEntries(text)[1].note, "spec")
check("sanitizeEntry rejects zero length", M.sanitizeEntry({ project: "x", start: 5, end: 5 }), null)
check("sanitizeEntry rejects nameless", M.sanitizeEntry({ project: " ", start: 1, end: 5 }), null)

check("clipping keeps the sync marker",
  M.entriesInRange([{ id: "s", project: "acme", note: "", start: day + 9 * 3600, end: day + 10 * 3600, moneybird: { id: "9", syncedAt: 1 } }],
    day, M.dayEnd(day))[0].moneybird.id, "9")

// Quick input grammar
check("parse plain", M.parseQuickInput("acme"), { project: "acme", note: "", backdateMinutes: 0 })
check("parse note", M.parseQuickInput("acme: pairing on the bar"), { project: "acme", note: "pairing on the bar", backdateMinutes: 0 })
check("parse backdate", M.parseQuickInput("acme +45"), { project: "acme", note: "", backdateMinutes: 45 })
check("parse both", M.parseQuickInput("acme +45: writing the spec"), { project: "acme", note: "writing the spec", backdateMinutes: 45 })
check("parse keeps numeric names", M.parseQuickInput("sprint 45"), { project: "sprint 45", note: "", backdateMinutes: 0 })
check("parse empty", M.parseQuickInput("  "), { project: "", note: "", backdateMinutes: 0 })

// Ranking
check("fuzzy misses", M.fuzzyScore("zz", "acme"), -1)
var projects = [
  { name: "acme-bar", lastUsed: 100 },
  { name: "grab", lastUsed: 900 },
  { name: "beta", lastUsed: 500 }
]
check("rank empty is recency", M.rankProjects(projects, "").map(function(r) { return r.name }), ["grab", "beta", "acme-bar"])
check("rank prefers word starts", M.rankProjects(projects, "ab")[0].name, "acme-bar")
check("rank filters", M.rankProjects(projects, "zz").length, 0)

// Projects
check("touch adds", M.touchProject([], "acme", 10), [{ name: "acme", lastUsed: 10 }])
check("touch updates in place", M.touchProject([{ name: "acme", lastUsed: 1 }], "ACME", 20), [{ name: "acme", lastUsed: 20 }])
check("touch ignores empty", M.touchProject([], "  ", 10), [])
check("hue is stable", M.projectHue("acme"), M.projectHue("ACME"))

// Export
var csv = M.toCsv([{ id: "a", project: "ac,me", note: 'say "hi"', start: day + 9 * 3600, end: day + 10 * 3600 }])
check("csv header", csv.split("\n")[0], "date,start,end,project,note,seconds,hours")
check("csv quoting", csv.split("\n")[1], '2026-08-26,09:00,10:00,"ac,me","say ""hi""",3600,1.00')

// Sync bookkeeping
var pending = [
  { id: "a", project: "fizzy", note: "n", start: 100, end: 4000 },
  { id: "b", project: "admin", note: "", start: 4000, end: 4030 },
  { id: "c", project: "acme", note: "", start: 5000, end: 9000, moneybird: { id: "999", syncedAt: 12 } }
]
check("unsynced skips what is done", M.unsyncedEntries(pending).map(function(e) { return e.id }), ["a", "b"])
check("payload stays narrow", Object.keys(M.syncPayload(pending)[0]).sort(), ["end", "id", "note", "project", "start"])

var applied = M.applySyncResults(pending, [
  { id: "a", moneybirdId: "4965", skipped: false, error: null },
  { id: "b", moneybirdId: null, skipped: true, error: "shorter than a minute" }
], 777)
check("success records the id", applied[0].moneybird, { syncedAt: 777, id: "4965" })
check("skipped settles too", applied[1].moneybird, { syncedAt: 777, skipped: true, reason: "shorter than a minute" })
check("nothing owed after", M.unsyncedEntries(applied).length, 0)

// Editing an entry must never change whether it has been sent.
var booked = { id: "z", project: "acme", note: "old", start: 10, end: 3610, moneybird: { id: "77", syncedAt: 5 } }
check("edit keeps the sync marker", M.editedEntry(booked, { note: "new" }).moneybird, { id: "77", syncedAt: 5 })
check("edit applies the change", M.editedEntry(booked, { note: "new" }).note, "new")
check("edit of an unsent entry stays unsent", M.editedEntry({ id: "y", project: "a", note: "", start: 1, end: 61 }, { end: 121 }).moneybird, undefined)
check("edited entry is still owed or not accordingly", M.unsyncedEntries([M.editedEntry(booked, { end: 7200 })]).length, 0)

// A failure records nothing, so the entry stays owed and the next run retries.
var failed = M.applySyncResults(pending, [{ id: "a", moneybirdId: null, skipped: false, error: "offline" }], 777)
check("failure leaves it owed", M.unsyncedEntries(failed).map(function(e) { return e.id }), ["a", "b"])
check("failures are reported", M.syncErrors([{ id: "a", error: "offline" }, { id: "b", skipped: true, error: "too short" }]), ["offline"])

// Sync state survives the file round trip.
check("sync survives serialization", M.parseEntries(M.serializeEntries(applied))[0].moneybird.id, "4965")
check("garbage sync state is dropped", M.sanitizeEntry({ project: "x", start: 1, end: 99, moneybird: {} }).moneybird, undefined)

// Bounds. Every string is cleaned and cut, every collection is capped, and
// the caps are the ones LIMITS declares.
var L = M.LIMITS
var long = new Array(L.noteChars + 50).join("x")
check("cleanText trims", M.cleanText("  hi  ", 10), "hi")
check("cleanText strips control characters", M.cleanText("a\tb\nc\u0000d", 10), "a b c d")
check("cleanText cuts", M.cleanText(long, 5), "xxxxx")
check("cleanText handles null", M.cleanText(null, 5), "")
check("utf8Length ascii", M.utf8Length("abc"), 3)
check("utf8Length multibyte", M.utf8Length("é€😀"), 2 + 3 + 4)
check("entry project is cut", M.sanitizeEntry({ project: long, start: 1, end: 100 }).project.length, L.projectChars)
check("entry note is cut", M.sanitizeEntry({ project: "x", note: long, start: 1, end: 100 }).note.length, L.noteChars)
check("entry rejects a year-long span", M.sanitizeEntry({ project: "x", start: 1, end: 1 + L.spanSeconds + 1 }), null)
check("entry rejects far-future times", M.sanitizeEntry({ project: "x", start: L.maxEpoch + 1, end: L.maxEpoch + 2 }), null)
check("entry rejects negative times", M.sanitizeEntry({ project: "x", start: -5, end: 5 }), null)
check("running clamps a future start", M.sanitizeRunning({ project: "x", start: 5000 }, 4000).start, 4000)
check("running rejects nameless", M.sanitizeRunning({ project: "\n", start: 5 }, 10), null)
check("edit cannot smuggle a long note", M.editedEntry({ id: "a", project: "x", note: "", start: 1, end: 100 }, { note: long }).note.length, L.noteChars)
check("edit cannot blank the project", M.editedEntry({ id: "a", project: "x", note: "", start: 1, end: 100 }, { project: "  " }).project, "x")
check("quick input is cut", M.parseQuickInput(long + ": " + long).project.length, L.projectChars)
check("quick input note is cut", M.parseQuickInput("acme: " + long).note.length, L.noteChars)
check("quick input backdate is clamped", M.parseQuickInput("acme +9999").backdateMinutes <= L.backdateMinutes, true)
check("clampMinutes", [M.clampMinutes("12", 10), M.clampMinutes(-3, 10), M.clampMinutes("x", 10)], [10, 0, 0])

var crowd = []
for (var c = 0; c < L.projects + 20; c++) crowd.push({ name: "p" + c, lastUsed: c })
check("projects are capped to the most recent", M.sanitizeProjects(crowd).length, L.projects)
check("the most recent survive", M.sanitizeProjects(crowd)[0].name, "p" + (L.projects + 19))
check("touch keeps the cap", M.touchProject(M.sanitizeProjects(crowd), "new", 99999).length, L.projects)
check("touch puts the new one first", M.touchProject(M.sanitizeProjects(crowd), "new", 99999)[0].name, "new")

var lines = []
for (var e = 0; e < L.entries + 5; e++) lines.push(JSON.stringify({ id: "e" + e, project: "x", start: e * 100, end: e * 100 + 50 }))
var parsedLog = M.parseEntries(lines.join("\n"))
check("log is capped", parsedLog.length, L.entries)
check("log keeps the newest", parsedLog[parsedLog.length - 1].id, "e" + (L.entries + 4))
check("log skips absurd lines", M.parseEntries(JSON.stringify({ project: "x", start: 1, end: 100, pad: long + long + long + long + long + long + long + long + long }) + "\n" + lines[0]).length, 1)
check("append keeps the cap", M.appendEntry(parsedLog, { id: "z", project: "x", start: 1, end: 2 }).length, L.entries)
check("append keeps the newest", M.appendEntry(parsedLog, { id: "z", project: "x", start: 1, end: 2 })[L.entries - 1].id, "z")

var owed = []
for (var o = 0; o < L.syncBatch + 10; o++) owed.push({ id: "o" + o, project: "x", note: "", start: o, end: o + 100 })
check("one push carries one batch", M.syncPayload(owed).length, L.syncBatch)
check("results over the batch are cut", M.parseSyncResults(JSON.stringify(owed)).length, L.syncBatch)
check("results must be an array", M.parseSyncResults("{}"), null)
check("results must parse", M.parseSyncResults("nope"), null)
check("results have a size ceiling", M.parseSyncResults("[" + new Array(L.syncResultBytes).join(" ") + "]"), null)
check("sync errors are cut", M.syncErrors([{ id: "a", error: long }])[0].length, L.syncErrorChars)
check("sync reason is cut", M.sanitizeSync({ id: "1", reason: long }).reason.length, L.syncErrorChars)

var many = []
for (var m = 0; m < L.reportRows + 3; m++) many.push({ id: "m" + m, project: "proj" + m, note: "", start: m, end: m + 60 })
var report = M.summaryLines(many, "ALL")
check("report is capped", report.length, L.reportRows + 2)
check("report says what it left out", report[L.reportRows], "... and 3 more")
check("byProject is prototype-safe", M.byProject([{ project: "__proto__", start: 0, end: 60 }, { project: "constructor", start: 0, end: 60 }]).length, 2)

// Status
check("status stopped", M.statusLine(null, 0), "stopped")
check("status running", M.statusLine({ project: "acme", note: "" }, 5040), "acme 1:24")
check("status note", M.statusLine({ project: "acme", note: "specs" }, 5040), "acme 1:24 (specs)")

if (failures) {
  console.error("\n" + failures + " failing")
  process.exit(1)
}
console.log("all model checks passed")
