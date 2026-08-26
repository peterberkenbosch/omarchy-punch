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
check("hourFraction half", M.hourFraction(1800), 0.5)
check("hourFraction wraps", M.hourFraction(3600 + 1800), 0.5)

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

// Status
check("status stopped", M.statusLine(null, 0), "stopped")
check("status running", M.statusLine({ project: "acme", note: "" }, 5040), "acme 1:24")
check("status note", M.statusLine({ project: "acme", note: "specs" }, 5040), "acme 1:24 (specs)")

if (failures) {
  console.error("\n" + failures + " failing")
  process.exit(1)
}
console.log("all model checks passed")
