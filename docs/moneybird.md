# Moneybird setup

Punch pushes finished entries to [Moneybird](https://www.moneybird.com) through
its official CLI. This is the long version; the [README](../README.md#moneybird)
has the summary.

The shape of it: **the log on disk is the truth, and Moneybird catches up to
it.** Stopping the clock sends the entry. If that fails — you were on a train,
the token expired, a project is not mapped yet — the entry stays in
`entries.jsonl` and in the queue, and gets retried. Nothing is ever lost waiting
for a network.

## 1. Install the CLI

Punch shells out to `moneybird-cli`, Moneybird's own tool. It needs `curl` and
`jq`, both of which Omarchy already has.

```bash
curl -fsSL https://raw.githubusercontent.com/moneybird/moneybird-cli/main/install.sh | bash
```

The installer wants `/usr/local/bin`. If you would rather not use sudo, clone it
and link it into your own path instead:

```bash
git clone https://github.com/moneybird/moneybird-cli.git ~/.moneybird-cli
ln -sf ~/.moneybird-cli/moneybird-cli ~/.local/bin/moneybird-cli
moneybird-cli --version
```

## 2. Get a token

In Moneybird: **Settings → External applications and AI connections → New API
token**.

The token needs three scopes:

| Scope | Why |
|---|---|
| `time_entries` | writing the entries themselves |
| `sales_invoices` | Moneybird requires it on the time-entry create call |
| `settings` | reading the project and user lists, which is how Punch decides where time goes |

`settings` is the one that catches people out. Without it the token is perfectly
valid, writes time entries happily, and still cannot read the two lists needed
to work out which project an entry belongs to — and Moneybird reports that as a
plain 401, the same answer it gives for a token it has never seen.

A token is also accepted at login without any of this being checked: `login`
only writes local config and never calls the API. `punch-moneybird doctor`
prints exactly which endpoints your token can reach.

Then log in. Do this yourself rather than pasting the token into a script or a
chat window:

```bash
moneybird-cli login <token>
```

The token is stored under `~/.config/moneybird-cli/`, directory mode `700`,
files `600`. If you have more than one administration:

```bash
moneybird-cli administration list
moneybird-cli administration use <id>
```

## 3. Turn the push on

Sync is off until you say otherwise. Set `moneybirdSync` on the Punch entry in
`~/.config/omarchy/shell.json`:

```json
{ "id": "pb.punch", "moneybirdSync": true }
```

`shell.json` hot-reloads, so the setting takes effect on save.

## 4. Map your projects

`~/.config/punch/moneybird.json` decides where time lands:

```json
{
  "userId": "",
  "defaultBillable": true,
  "projects": {
    "admin":    { "billable": false, "project": null },
    "acme-web": { "project": "Acme website", "contact": "Acme Corp" }
  }
}
```

A Punch project with no entry here is matched against your Moneybird projects
**by name**, case-insensitively. Calling a project `fizzy` on both sides is all
the configuration it needs. Everything else is one line here.

| Key | Meaning |
|---|---|
| `project` | Moneybird project name to use instead of the Punch one. `null` books the time with no project attached. |
| `contact` | Moneybird contact to attach, matched on company name or full name. |
| `billable` | Overrides `defaultBillable` for this project. |
| `defaultBillable` | Top level. Applies to every project that does not say otherwise. Defaults to `true`. |
| `userId` | Whose time this is. Resolved automatically when the administration has exactly one person who can track time; set it by hand otherwise. |

### Unmapped projects are refused, not guessed

If a Punch project matches no Moneybird project and has no mapping, the entry is
**not** sent. It stays queued and tells you what to map.

Sending it anyway would put billable time against no project at all, which is
the kind of thing you find out about on an invoice. Guessing is fine for a
project name; it is not fine for money.

### Descriptions

An entry's note becomes the Moneybird `description`, which may be shown on the
invoice. Three ways to write one, all of them fast:

```bash
punch start "acme: checkout redesign"   # at the start
punch note "checkout redesign"          # any time after
```

or open the day panel and press `d` — on the running entry, or on any finished
row you have moved the cursor to — or open the quick switcher and type a line
that is nothing but a note: `: checkout redesign`.

Editing the note on a row that already carries the sync tick changes it in Punch
only. Moneybird keeps the description it was given.

An entry with no note is sent with its Punch project name as the description, so
nothing ever reaches Moneybird blank.

## 5. Check before you commit anything

```bash
punch-moneybird doctor
```

That prints the administration it is talking to, the user id it resolved, the
config file it is reading, and every Moneybird project it can see — which is
also the list your Punch project names are matched against.

```bash
punch-moneybird projects     # ids, names, state
punch-moneybird contacts     # ids and names
```

Then push whatever is waiting:

```bash
punch sync
punch sync status
```

## Living with it

The day panel shows `n entries waiting to sync` while there is a backlog, and
puts a tick on every row that has reached Moneybird. Three consecutive failures
raise one notification, and clicking it retries.

Retries back off 1, 2, 4, 8, 16, 30 minutes and then stay at 30, so a token that
needs re-issuing is not hammered, and a laptop that comes back online recovers
on its own.

`punch sync` forces a run immediately, whatever the backoff is doing.

## Bounds and lifecycle

The push is the one place Punch talks to a network and runs somebody else's
program, so it is fenced on every side.

**What goes in.** One run carries at most 50 entries. The service picks the
oldest owed ones; a larger backlog drains in rounds of 50, each round
scheduled as soon as the previous one lands. The helper reads its input
through a 1 MiB cap and checks every entry before doing anything: a string
id of at most 64 characters, a project of at most 80, a note of at most 500,
no control characters in any of them, and sane times. The mapping file is
capped at 64 KiB.

**What comes back.** One result per entry attempted, never more than 50, each
error cut to 200 characters. The service parses the answer only if it is
under 256 KiB and is a JSON array; anything else is a failed run, not data.
Every `moneybird-cli` answer is capped at 4 MiB before it is read.

**Deadlines.** Every `moneybird-cli` call runs under `timeout(1)` with
`PUNCH_MONEYBIRD_TIMEOUT` seconds (default 30) and a hard kill five seconds
after that. The run has a budget of `PUNCH_MONEYBIRD_BUDGET` seconds (default
90); entries not reached are simply not in the results and go out next time.
The service keeps a two-minute watchdog on top, as the last fence.

**Teardown.** The helper runs each call as a background job it waits on, so a
SIGTERM is acted on at once rather than after the call: the call in flight is
terminated (`timeout` forwards the signal to the process group it made for
the call, which is what takes `curl` down with `moneybird-cli`), the work
directory under `$XDG_RUNTIME_DIR` is removed, and the helper exits. The
service starts the helper through `setsid --wait --fork`, so the process
Quickshell holds is a thin parent; when the shell reloads or the service is
destroyed, Quickshell kills that parent, the helper notices within half a
second that it has been orphaned, and tears itself down the same way.
Cancelling (the watchdog, or switching `moneybirdSync` off mid-push) is
SIGTERM to the parent, then SIGKILL five seconds later. A cancelled or
timed-out run records nothing, however far it got: the next run re-sends
what is still owed. That means a call cancelled after Moneybird accepted it
but before the answer arrived can leave one entry there twice; the tick in
the panel is what to check.

**The description on the command line.** `moneybird-cli time_entries create`
takes the description only as `--description <text>`, so the note is an
argument of that process for the length of the call, visible in the process
list to other users of the same machine unless `/proc` is mounted with
`hidepid`. Notes are work descriptions headed for an invoice, not secrets;
do not put anything in one that should not be.

`bash test/moneybird-test.sh` runs the helper against a stub `moneybird-cli`
that hangs, and checks each of the three teardown paths leaves no process
and no work directory behind.

## Troubleshooting

| What you see | What it means |
|---|---|
| `moneybird sync is off` | `moneybirdSync` is not `true` on the bar entry in `shell.json`. |
| `moneybird-cli is not logged in` | Run `moneybird-cli login <token>`. |
| `Moneybird refused to list projects` (or `users`) | The token is valid but lacks the `settings` scope. Create a new one with all three scopes. |
| `Moneybird rejected the token` | The token itself is not accepted. Create a new one. |
| `could not work out which Moneybird user to book time for` | More than one candidate user. Run `punch-moneybird doctor`, then set `userId` in the mapping file. |
| `no Moneybird project named "x"` | Either rename the Punch project to match, or map it. `punch-moneybird projects` lists the real names. |
| `no Moneybird contact matches "x"` | The `contact` in your mapping is not an exact company or full name. `punch-moneybird contacts` lists them. |
| Entries stay queued and nothing is logged | `punch sync status` prints the last error verbatim. |
| An entry never appears and never errors | Shorter than a minute. Moneybird rounds to whole minutes and needs at least one, so Punch marks those settled rather than queueing them forever. |
| `moneybird-cli ... did not answer within 30s` | One call hit its deadline. The entry stays owed and is retried; raise `PUNCH_MONEYBIRD_TIMEOUT` on a slow link. |
| `the Moneybird push did not finish within two minutes` | The service's watchdog cancelled the run. Nothing from it was recorded; the backoff retries. |
| `expected a JSON array of at most 50 well-formed entries` | Only when driving the helper by hand: the input broke one of the bounds above. |

To watch a push happen, run the pieces by hand — the pusher is a plain script
and reads from a file as happily as from the service:

```bash
echo '[{"id":"t1","project":"fizzy","note":"test","start":1787700000,"end":1787703600}]' \
  | punch-moneybird push
```

Four environment variables help when testing: `PUNCH_MONEYBIRD_CONFIG` points
at a different mapping file, `PUNCH_MONEYBIRD_CLI` points at a different
binary — which is how the push path is exercised against a stub instead of a
real administration — and `PUNCH_MONEYBIRD_TIMEOUT` and
`PUNCH_MONEYBIRD_BUDGET` set the per-call deadline and the per-run budget in
seconds.

## What this does not do

Entries are only ever **created**. Editing a duration or deleting an entry in
Punch after it has synced does not propagate: Moneybird keeps the original. The
tick in the day panel is how you tell which rows are already committed. Fix
those in Moneybird directly, or delete there and let Punch re-send.

There is no pull. Time entered directly in Moneybird is invisible to Punch, and
Punch will happily add more alongside it.
