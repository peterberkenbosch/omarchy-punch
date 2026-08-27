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

The token needs the `time_entries` scope. Moneybird also requires the API user
to have sales-invoice access for this endpoint, which its own docs state on the
create call — a token with only `time_entries` will be accepted at login and
then refused at the first push.

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

or open the day panel and press `d`, or open the quick switcher and type a line
that is nothing but a note: `: checkout redesign`.

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

## Troubleshooting

| What you see | What it means |
|---|---|
| `moneybird sync is off` | `moneybirdSync` is not `true` on the bar entry in `shell.json`. |
| `moneybird-cli is not logged in` | Run `moneybird-cli login <token>`. |
| `could not work out which Moneybird user to book time for` | More than one candidate user. Run `punch-moneybird doctor`, then set `userId` in the mapping file. |
| `no Moneybird project named "x"` | Either rename the Punch project to match, or map it. `punch-moneybird projects` lists the real names. |
| `no Moneybird contact matches "x"` | The `contact` in your mapping is not an exact company or full name. `punch-moneybird contacts` lists them. |
| Entries stay queued and nothing is logged | `punch sync status` prints the last error verbatim. |
| An entry never appears and never errors | Shorter than a minute. Moneybird rounds to whole minutes and needs at least one, so Punch marks those settled rather than queueing them forever. |

To watch a push happen, run the pieces by hand — the pusher is a plain script
and reads from a file as happily as from the service:

```bash
echo '[{"id":"t1","project":"fizzy","note":"test","start":1787700000,"end":1787703600}]' \
  | punch-moneybird push
```

Two environment variables help when testing: `PUNCH_MONEYBIRD_CONFIG` points at
a different mapping file, and `PUNCH_MONEYBIRD_CLI` points at a different
binary — which is how the push path is exercised against a stub instead of a
real administration.

## What this does not do

Entries are only ever **created**. Editing a duration or deleting an entry in
Punch after it has synced does not propagate: Moneybird keeps the original. The
tick in the day panel is how you tell which rows are already committed. Fix
those in Moneybird directly, or delete there and let Punch re-send.

There is no pull. Time entered directly in Moneybird is invisible to Punch, and
Punch will happily add more alongside it.
