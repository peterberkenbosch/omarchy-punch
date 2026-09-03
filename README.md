# Punch

Time tracking for [Omarchy](https://omarchy.org), built for the case that
actually happens forty times a day: you switch what you are working on and you
do not want to think about the tracker.

The bar pill is not a launcher for a timer. It **is** the timer — the project
and the running clock, in that project's color, so "what am I on and for how
long" costs a glance and no clicks. Starting the clock
on the thing you were doing an hour ago is one keypress; starting it on
something new is a keypress and a few letters.

![The Punch pill in the bar, running and stopped](docs/pill.png)

Running and stopped: the pill carries the project and the clock while it runs,
and collapses to a quiet glyph when it does not.

## Install

Punch is one plugin wearing three hats. The **service** owns the clock, the
**bar widget** renders it, and the **overlay** is the quick switcher, so the
running entry survives a panel closing, a bar reload, or a monitor appearing.

```bash
omarchy plugin add https://github.com/peterberkenbosch/omarchy-punch.git --enable --yes
ln -sf ~/.config/omarchy/plugins/pb.punch/bin/punch ~/.local/bin/punch
```

Or, working on a local checkout:

```bash
git clone git@github.com:peterberkenbosch/omarchy-punch.git ~/.config/omarchy/plugins/pb.punch
omarchy-shell shell rescanPlugins
omarchy plugin enable pb.punch --section right
```

Then two keybindings in `~/.config/hypr/bindings.lua`. `SUPER+T` is Omarchy's
float toggle, so Punch sits beside it:

```lua
o.bind("SUPER + SHIFT + T", "Punch: start/stop", "punch toggle")
o.bind("SUPER + ALT + T", "Punch: switch project", "punch pick")
```

## Uninstall

```bash
omarchy plugin remove pb.punch --yes
rm -f ~/.local/bin/punch
```

Then drop the two keybindings from `bindings.lua`. Your time log is left alone;
delete it yourself if you want it gone:

```bash
rm -rf ~/.local/share/punch ~/.config/punch
```

## The pill

Stopped, it is a quiet glyph. Running, it becomes a pill in the project's color
carrying the name and the elapsed time.

| Interaction | What it does |
|---|---|
| left | open the day panel |
| right | stop, or resume the last project if stopped |
| middle | open the quick switcher |
| scroll | walk recent projects **without** stopping the clock |

## The quick switcher

`SUPER+ALT+T`. One input, no chrome. Type enough of a project to tell it apart
and press enter. A name that matches nothing offers to create it, so there is no
separate "new project" step.

The typed line is the whole grammar:

```
acme                        start acme now
acme: pairing on the bar    start acme with a note
acme +45                    start acme as if it began 45 minutes ago
acme +45: writing the spec  both
: reviewing the migration   note this on whatever is already running
```

A line that is nothing but a note says something about the work in progress
rather than starting new work, so the same keybind that switches projects is
also how you describe the one you are on.

`+45` rather than a bare `45` so a project legitimately named `sprint 45` stays
typeable. A backdate can never reach behind the last logged entry — Punch clips
it to that boundary and says so, rather than quietly double-billing the overlap.

## The day panel

![The Punch day panel](preview.png)

Left-click the pill. Under the clock is the note on the running entry, and every
finished row carries one too: click the line, or press `d`, and it becomes a
field. `enter` saves, `esc` discards, clicking away saves.

The note is the description Moneybird may print on an invoice, so it is worth
writing while the work is fresh rather than only in the second the clock starts,
which is the one moment you have nothing to say yet — and worth fixing later,
when you remember what the work actually was.

The strip across the top is the shape of the day, one band
per project, gaps shown as gaps so you can see what you failed to track. Below
it: today and this week, per-project totals, and the day's entries with the
running stretch sitting in the list like any other row.

| Key | |
|---|---|
| `enter` | resume the selected row's project |
| `d` | write the note on the selected entry, or the running one |
| `s` | start / stop |
| `p` | quick switcher |
| `+` / `-` | lengthen or shorten the selected entry by 5 minutes |
| `x` | delete the selected entry |
| `j` `k` / arrows | move |
| `esc` | close |

## The CLI

Every subcommand is one IPC call into the running shell, so the terminal and the
pill are never two copies of the truth.

```
punch                     what is running right now (and whether it is saving)
punch start [text]        start (defaults to the last project; takes the grammar above)
punch stop
punch toggle
punch note [text]         set the note on the running entry (empty clears it)
punch discard             drop the running entry without logging it
punch trim <minutes>      cut the last N minutes off the running entry
punch next | prev         walk recent projects
punch today
punch week
punch csv [YYYY-MM-DD]    finished entries as CSV
punch projects
punch pick                open the quick switcher
punch panel               open the day panel
```

That makes the tracker scriptable. A direnv-style hook that starts the right
project when you `cd` into a client repo is a couple of lines on top of
`punch start`.

## Idle

The shell already knows when you walk away. Come back after fifteen idle minutes
with the clock still running and Punch raises one notification: clicking it
trims the away time off the entry and picks it straight back up, doing nothing
keeps it. Punch never edits the log on its own — whether lunch counts is a
judgement call, so it asks.

Set `idleThresholdSec` to `0` to turn it off.

## Moneybird

Finished entries can be pushed to [Moneybird](https://www.moneybird.com) through
its official CLI. Stopping the clock sends the entry; anything that fails
because you were offline or your token expired stays queued and is retried with
a widening backoff, so the log on disk is always the truth and Moneybird catches
up to it.

Install [moneybird-cli](https://github.com/moneybird/moneybird-cli) following
its own README (a manual route without the installer is in
[docs/moneybird.md](docs/moneybird.md)), then log in:

```bash
moneybird-cli login <token>       # scopes: time_entries, sales_invoices, settings
```

Then set `moneybirdSync` to `true` on the Punch entry in `shell.json`, and map
your projects in `~/.config/punch/moneybird.json`:

```json
{
  "defaultBillable": true,
  "projects": {
    "admin":    { "billable": false, "project": null },
    "acme-web": { "project": "Acme website", "contact": "Acme Corp" }
  }
}
```

A Punch project with no entry here is matched against your Moneybird projects by
name, so calling one `fizzy` on both sides needs no configuration at all. One
that matches nothing and is not mapped is **refused, not guessed** — booking it
anyway would put billable time against no project, which is the kind of thing
you find out about on an invoice.

```bash
punch sync                  # push anything not yet in Moneybird
punch sync status           # how far behind the push is
punch-moneybird doctor      # login, resolved user, and your Moneybird projects
```

The day panel shows `n entries waiting to sync` while there is a backlog, and
puts a tick on every row that has reached Moneybird.

Entries are only ever **created** — editing or deleting one after it has synced
does not propagate.

A push is a subprocess with a contract: at most 50 entries in, at most 50
results out, a deadline on every `moneybird-cli` call and a budget on the run,
and a teardown of the whole process tree when the push is cancelled, times
out, or the shell reloads underneath it. The entry note is handed to
`moneybird-cli` as a command-line argument, because that is the only way it
takes one, so it is visible in the process list for the length of that call.
Details in [docs/moneybird.md](docs/moneybird.md#bounds-and-lifecycle).

**[Full setup, mapping reference, and troubleshooting →](docs/moneybird.md)**

## Settings

Inline on the bar entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "pb.punch", "idleThresholdSec": 900, "roundToMinutes": 15, "showProjectName": true, "hideWhenStopped": false }
```

| Key | Default | |
|---|---|---|
| `idleThresholdSec` | `900` | ask about idle time after this long; `0` disables |
| `roundToMinutes` | `0` | round finished entries **up** to the next N minutes |
| `moneybirdSync` | `false` | push finished entries to Moneybird (see above) |
| `showProjectName` | `true` | show the project name in the bar, not just the time |
| `hideWhenStopped` | `false` | hide the pill entirely when nothing is running |

Rounding applies when an entry stops, never to the live timer: what you watch is
real time, what lands in the log is billable time.

## Data

```
~/.local/share/punch/state.json     what is running now, plus known projects
~/.local/share/punch/entries.jsonl  one JSON object per finished entry
```

Line-oriented on purpose, so the log stays greppable, diffable, and repairable
without the shell. An entry that crosses midnight is stored once and clipped
into both days when it is read, never counted twice.

### How the files are touched

The service never opens either file by pathname. Every read and write goes
through `bin/punch-store`, a small Perl script (Perl is on every Omarchy
install) that:

- opens the data directory one component at a time without following
  links, refuses an ancestor that is world-writable and not sticky, creates
  the final directory `0700` if it is missing, and puts it back to `0700` if
  it is not;
- opens each file relative to that held directory descriptor, again without
  following links, and refuses anything that is not a regular file owned by
  you or that is over its byte ceiling;
- publishes a write by filling a fresh `O_EXCL` temp file in the same
  directory, fsyncing it, and renaming it over the target, then fsyncing the
  directory. The file is always either the old text or the whole new text,
  and a link left at its name is replaced rather than written through. The
  service states the byte count it is sending and the helper refuses any
  other length, so a broken pipe can never publish an empty log.

If the helper refuses (a symlinked directory, a file that is not yours, a log
over the ceiling), Punch keeps working in memory, stops writing, raises one
notification, and `punch` reports `[not saving: ...]` after the status line.
Persistence comes back on the next action once the directory is fixed.

The shell only ever learns that a file changed under it through inotify; it
then asks the helper to read it again. An edit you make with a text editor is
picked up that way.

### Limits

Everything that comes in, from a keystroke, the CLI, the files, or Moneybird,
is cut to these before it is kept. They live in one place, `LIMITS` at the
top of `Model.js`, and the helpers quote the same numbers.

| | |
|---|---|
| project name | 80 characters |
| note | 500 characters |
| a line typed into the switcher or `punch start` | 1000 characters |
| known projects | 200, least recently used dropped first |
| finished entries | 20,000, oldest dropped first |
| `state.json` | 64 KiB |
| `entries.jsonl` | 4 MiB |
| entry length | one year; longer is discarded as junk |
| backdate or trim | one week |
| single `+`/`-` edit | one day |
| rows drawn in the day panel | 200 newest |
| projects listed in `punch today` / `week` | 200, then `... and N more` |
| entries per Moneybird push | 50; a backlog drains in rounds |

Control characters, including newlines, are replaced by spaces in every
string, so the one-line answers over IPC and the line-per-entry log cannot be
broken from the inside.

## Hacking on it

Omarchy watches `~/.config/omarchy/plugins/` and reloads plugin code on save,
but in practice that did not swap either the service or the bar widget here:
the old service kept the `punch` IPC target, and the widget kept its old
component. **Run `omarchy restart shell` after editing any QML in this plugin**,
or you will spend a while debugging code that is not running.

`Model.js` is Qt-free so the arithmetic that decides what gets billed can be
checked without a compositor, and the two helpers are plain scripts that run
against a throwaway directory and a stub `moneybird-cli`:

```bash
bash test/run.sh          # all of the below
node test/model-test.js   # durations, parsing, ranking, sync bookkeeping, limits
bash test/store-test.sh   # punch-store: round trip, ceilings, links, FIFOs, modes
bash test/moneybird-test.sh   # punch-moneybird: bounds, deadline, cancel, orphan teardown
```

The Moneybird test starts a push against a CLI stub that hangs, then kills it
three ways (its own deadline, SIGTERM, and SIGKILL of its parent) and checks
that the stub and the child it spawned are gone each time.

## Not in this version

- No Toggl or Harvest sync. Moneybird is the one backend so far; the shape it
  uses — a script the service shells out to — is where another would hang.
- No pause on lock. Idle detection covers the real case.
- Entries are edited in 5-minute steps, not by dragging their edges.

## License

MIT.
