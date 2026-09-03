#!/bin/bash
# Run with: bash test/moneybird-test.sh
# Exercises bin/punch-moneybird against a stub moneybird-cli: the input
# bounds, a normal push, a call that hangs (per-call deadline), a run that is
# cancelled (SIGTERM), and a run whose parent dies (orphan teardown). The
# stub records the pids of itself and of a child it spawns, standing in for
# moneybird-cli and the curl underneath it, so "no process left behind" is
# checked, not assumed.

set -u
cd "$(dirname "$0")/.." || exit 1
HELPER=$PWD/bin/punch-moneybird

failures=0
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/punch-moneybird-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
export XDG_RUNTIME_DIR=$ROOT/run
mkdir -p "$XDG_RUNTIME_DIR"
export PUNCH_MONEYBIRD_CONFIG=$ROOT/moneybird.json
export PUNCH_MONEYBIRD_CLI=$ROOT/stub-cli
export STUB_MODE=ok
export STUB_PIDS=$ROOT/pids

cat > "$PUNCH_MONEYBIRD_CONFIG" <<'JSON'
{ "userId": "7", "projects": { "acme": { "project": "Acme website" } } }
JSON

# The stub answers like moneybird-cli for the calls the pusher makes.
# STUB_MODE=hang makes time_entries create sit forever (with a child, like
# curl); STUB_MODE=flood makes projects list answer with far too much.
cat > "$PUNCH_MONEYBIRD_CLI" <<'STUB'
#!/bin/bash
echo "$$" >> "${STUB_PIDS:-/dev/null}"
resource=${1:-}; action=${2:-}
case "$resource $action" in
  "administration current") echo "Test administration"; exit 0 ;;
  "users list") echo '[{"id":"7","name":"Me","permissions":["time_entries"]}]'; exit 0 ;;
  "projects list")
    if [[ ${STUB_MODE:-ok} == flood ]]; then head -c 5000000 /dev/zero | tr '\0' 'x'; exit 0; fi
    echo '[{"id":"11","name":"Acme website","state":"active"}]'; exit 0 ;;
  "contacts list") echo '[]'; exit 0 ;;
  "time_entries create")
    if [[ ${STUB_MODE:-ok} == hang ]]; then
      sleep 600 & echo "$!" >> "${STUB_PIDS:-/dev/null}"; wait; exit 0
    fi
    echo '{"id":"9001"}'; exit 0 ;;
  *) echo "Error: unknown $resource $action"; exit 1 ;;
esac
STUB
chmod +x "$PUNCH_MONEYBIRD_CLI"

entry='{"id":"e1","project":"acme","note":"pairing","start":1787700000,"end":1787703600}'

# Every pid the stub recorded must be gone.
assert_no_leftovers() {
  local label=$1 pid alive=0
  sleep 0.3
  [[ -f $STUB_PIDS ]] || return 0
  while read -r pid; do
    [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null && alive=1 && echo "  still running: $pid $(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null)"
  done < "$STUB_PIDS"
  ((alive)) && fail "$label left processes behind"
  : > "$STUB_PIDS"
}

no_work_dirs() {
  [[ -z $(ls -A "$XDG_RUNTIME_DIR") ]] || fail "$1 left a work directory behind: $(ls -A "$XDG_RUNTIME_DIR")"
}

# --- input bounds
out=$("$HELPER" push </dev/null); [[ $out == "[]" ]] || fail "empty stdin should answer [] (got $out)"
"$HELPER" push <<<'{"not":"an array"}' >/dev/null 2>&1 && fail "a non-array should be refused"
"$HELPER" push <<<'[{"id":"x","project":"acme","start":5,"end":1}]' >/dev/null 2>&1 && fail "end before start should be refused"
"$HELPER" push <<<"[{\"id\":\"x\",\"project\":\"$(head -c 81 /dev/zero | tr '\0' 'p')\",\"start\":1,\"end\":100}]" >/dev/null 2>&1 && fail "a project over 80 chars should be refused"
"$HELPER" push <<<$'[{"id":"x","project":"a\\tb","start":1,"end":100}]' >/dev/null 2>&1 && fail "a control character should be refused"
many=$(jq -c -n '[range(51) | {id: ("e" + tostring), project: "acme", start: 1, end: 100}]')
"$HELPER" push <<<"$many" >/dev/null 2>&1 && fail "more than 50 entries should be refused"
head -c 1100000 /dev/zero | tr '\0' 'x' | "$HELPER" push >/dev/null 2>&1 && fail "more than 1 MiB of input should be refused"
no_work_dirs "input checks"

# --- a normal push
out=$("$HELPER" push <<<"[$entry]") || fail "a normal push should exit 0"
[[ $(jq -r '.[0].moneybirdId' <<<"$out") == 9001 ]] || fail "a normal push should record the Moneybird id (got $out)"
[[ $(jq 'length' <<<"$out") == 1 ]] || fail "one entry in, one result out"
assert_no_leftovers "a normal push"
no_work_dirs "a normal push"

# --- an oversized API answer is a failure, not data
STUB_MODE=flood "$HELPER" push <<<"[$entry]" >/dev/null 2>"$ROOT/err"; rc=$?
[[ $rc -ne 0 ]] && grep -q "more than" "$ROOT/err" || fail "a flooded projects list should fail the run (rc=$rc: $(cat "$ROOT/err"))"
assert_no_leftovers "a flooded answer"

# --- the per-call deadline: a hanging call becomes a per-entry error, promptly
start=$SECONDS
out=$(STUB_MODE=hang PUNCH_MONEYBIRD_TIMEOUT=1 "$HELPER" push <<<"[$entry]" 2>/dev/null); rc=$?
took=$((SECONDS - start))
[[ $rc -eq 0 ]] || fail "a timed-out call should still complete the run (rc=$rc)"
[[ $(jq -r '.[0].error' <<<"$out") == *"did not answer within 1s"* ]] || fail "the timeout should be reported per entry (got $out)"
((took <= 10)) || fail "a 1s deadline took ${took}s to fire"
assert_no_leftovers "a timed-out call"
no_work_dirs "a timed-out call"

# --- cancellation: SIGTERM mid-call tears the call down and exits
STUB_MODE=hang "$HELPER" push <<<"[$entry]" >/dev/null 2>&1 &
helper=$!
sleep 1.5
kill -TERM "$helper"
for _ in $(seq 1 40); do kill -0 "$helper" 2>/dev/null || break; sleep 0.1; done
kill -0 "$helper" 2>/dev/null && fail "the helper should exit within 4s of SIGTERM" && kill -KILL "$helper"
wait "$helper" 2>/dev/null
assert_no_leftovers "a cancelled push"
no_work_dirs "a cancelled push"

# --- orphaning: the parent dies (as the service's process does on a shell
# reload) and the helper tears itself down without being told
STUB_MODE=hang bash -c 'exec setsid --wait --fork "$0" push' "$HELPER" <<<"[$entry]" >/dev/null 2>&1 &
parent=$!
sleep 1.5
kill -KILL "$parent"
wait "$parent" 2>/dev/null
for _ in $(seq 1 40); do pgrep -f "punch-moneybird push" >/dev/null || break; sleep 0.1; done
pgrep -f "punch-moneybird push" >/dev/null && fail "an orphaned helper should exit within 4s" && pkill -KILL -f "punch-moneybird push"
assert_no_leftovers "an orphaned push"
sleep 0.5
no_work_dirs "an orphaned push"

if ((failures)); then
  echo; echo "$failures failing"
  exit 1
fi
echo "all moneybird checks passed"
