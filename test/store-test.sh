#!/bin/bash
# Run with: bash test/store-test.sh
# Exercises bin/punch-store against a throwaway data directory: the round
# trip, the byte ceilings, the byte-count contract, and every way a name in
# the directory can fail to be a plain file of ours.

set -u
cd "$(dirname "$0")/.." || exit 1
STORE=$PWD/bin/punch-store

failures=0
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
pass() { :; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/punch-store-test.XXXXXX")
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
export XDG_DATA_HOME=$ROOT/data
DIR=$XDG_DATA_HOME/punch
# Only the final directory is ever created; a missing data home is an error.
"$STORE" read state >/dev/null 2>&1 && fail "a missing XDG_DATA_HOME should be refused, not created"
mkdir "$XDG_DATA_HOME"

# --- a fresh install: read yields nothing, the directory is created private
out=$("$STORE" read state 2>&1); rc=$?
[[ $rc -eq 0 && -z $out ]] || fail "read of a missing file should print nothing and exit 0 (rc=$rc out=$out)"
[[ $(stat -c %a "$DIR") == 700 ]] || fail "data directory should be created 0700"

# --- round trip, and the file is private
printf '{"version":1}\n' | "$STORE" write state 14 || fail "write should succeed"
[[ $("$STORE" read state) == '{"version":1}' ]] || fail "read should return what was written"
[[ $(stat -c %a "$DIR/state.json") == 600 ]] || fail "written file should be 0600"
[[ -z $(ls -A "$DIR" | grep '\.tmp\.') ]] || fail "no temp file should be left behind"

# --- the byte-count contract refuses a short or long payload
printf 'short' | "$STORE" write state 14 2>/dev/null && fail "a payload shorter than announced should be refused"
printf 'far too long for six' | "$STORE" write state 6 2>/dev/null && fail "a payload longer than announced should be refused"
[[ $("$STORE" read state) == '{"version":1}' ]] || fail "a refused write should leave the old text in place"

# --- the byte ceilings
head -c 65537 /dev/zero | tr '\0' 'x' | "$STORE" write state 65537 2>/dev/null && fail "a state over 64 KiB should be refused"
head -c 65537 /dev/zero | tr '\0' 'x' > "$DIR/state.json"
"$STORE" read state >/dev/null 2>&1 && fail "a state over 64 KiB on disk should not be loaded"
printf '{}' | "$STORE" write state 2 || fail "the ceiling should be recoverable by writing a small file"

# --- a link at the file's name is never followed on read
ln -sf /etc/hostname "$DIR/entries.jsonl"
"$STORE" read entries >/dev/null 2>&1 && fail "a symlinked entries file should be refused on read"
# ...and is replaced, not written through, on write
printf 'x\n' | "$STORE" write entries 2 || fail "write over a symlink should succeed by replacing it"
[[ ! -L $DIR/entries.jsonl && $(cat "$DIR/entries.jsonl") == x ]] || fail "write should replace the link with a plain file"
[[ -s /etc/hostname || ! -e /etc/hostname ]] || fail "the link target must be untouched"

# --- a FIFO at the file's name is refused instead of blocking
rm -f "$DIR/entries.jsonl"; mkfifo "$DIR/entries.jsonl"
timeout 5 "$STORE" read entries >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] || fail "a FIFO should be refused promptly (rc=$rc)"
rm -f "$DIR/entries.jsonl"

# --- a data directory that is a link is refused
mv "$DIR" "$ROOT/elsewhere"; ln -s "$ROOT/elsewhere" "$DIR"
"$STORE" read state >/dev/null 2>&1 && fail "a symlinked data directory should be refused"
printf '{}' | "$STORE" write state 2 2>/dev/null && fail "a symlinked data directory should refuse writes"
rm "$DIR"; mv "$ROOT/elsewhere" "$DIR"

# --- a data directory that is too open is made private again
chmod 755 "$DIR"
"$STORE" read state >/dev/null || fail "read should still work on a 0755 directory"
[[ $(stat -c %a "$DIR") == 700 ]] || fail "the directory should be brought back to 0700"

# --- a world-writable ancestor without the sticky bit is refused
chmod 777 "$XDG_DATA_HOME"
"$STORE" read state >/dev/null 2>&1 && fail "a world-writable ancestor should be refused"
chmod 1777 "$XDG_DATA_HOME"
"$STORE" read state >/dev/null || fail "a sticky world-writable ancestor (like /tmp) is fine"
chmod 700 "$XDG_DATA_HOME"

# --- stale temp files from a crashed run are swept on the next write
touch -d '2 hours ago' "$DIR/.state.json.tmp.999999"
printf '{}' | "$STORE" write state 2 || fail "write should succeed alongside a stale temp"
[[ ! -e $DIR/.state.json.tmp.999999 ]] || fail "a stale temp file should be swept"

# --- usage errors
"$STORE" read nothing >/dev/null 2>&1; [[ $? -eq 2 ]] || fail "an unknown file name should be a usage error"
"$STORE" write state >/dev/null 2>&1 && fail "write without a byte count should be refused"

if ((failures)); then
  echo; echo "$failures failing"
  exit 1
fi
echo "all store checks passed"
