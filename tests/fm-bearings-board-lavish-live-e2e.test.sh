#!/usr/bin/env bash
# tests/fm-bearings-board-lavish-live-e2e.test.sh - live drift guard proving
# the real lavish-axi still behaves the way bin/fm-bearings-board.sh's session
# liveness check is written against.
#
# Why this file exists: the build's "is this board actually live" verdict comes
# from what lavish-axi emits, which is a surface the vendor controls and changes
# without notice. The defect this guards was exactly that - opening a session
# the captain had ended from the browser EXITS 0 while refusing to reopen, so a
# build that trusted the exit status armed a poll against a dead session and the
# board read "not listening" with nobody watching it. A stubbed lavish-axi can
# only confirm the assumption already written into the stub, so the assumption
# itself needs a run against the real tool.
#
# The captain-ended state is reached through the same server route the browser's
# End session button calls, so no browser is needed and nothing here depends on
# a human. Every open runs under lavish-axi's supported LAVISH_AXI_NO_OPEN=1
# contract, so no run of this guard launches a desktop browser. The artifact is
# a scratch page in a temporary directory, and the test ends its exact session
# and retires its detached listener before removing the page.
#
# Standard CI has no lavish-axi, so this reports a capability skip there. The
# portable counterpart in tests/fm-bearings-board.test.sh pins the build's logic
# in CI against a stub that reproduces these shapes. Run this guard after a
# lavish-axi upgrade and before trusting refreshed evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate default-on FM_BEARINGS_LAVISH_LIVE lavish-axi jq curl

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

LAB=''
BOARD=''

session_is_open() {
  local listing
  [ -n "$BOARD" ] || return 1
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$BOARD" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      split(rest, field, ",")
      if (field[1] == "open") { found = 1 }
    }
    END { exit found ? 0 : 1 }
  '
}

end_test_session() {
  local i=0
  [ -n "$BOARD" ] && [ -f "$BOARD" ] || return 0
  lavish-axi end "$BOARD" >/dev/null 2>&1 || return 1
  while [ "$i" -lt 50 ]; do
    session_is_open || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

retire_test_sources() {
  local i=0
  [ -n "$LAB" ] || return 0
  [ -d "$LAB/state/procevent" ] || return 0
  # The listener exits on its own once the session ends, and a home sweep
  # refuses to retire a source whose owner is alive but not yet readable, so
  # wait for the exit to settle instead of reading that window as a failure.
  while [ "$i" -lt 50 ]; do
    FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" \
      FM_PROCEVENT_CLAIM_ROOT="$LAB/procevent-claims" \
      "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

cleanup() {
  local rc=0
  [ -n "$LAB" ] || { fm_test_cleanup; return 0; }
  # End the provider session first, then synchronously retire its exact
  # test-home listener. Removing the artifact before the detached listener is
  # gone lets that process recreate an otherwise-empty temporary directory.
  end_test_session || rc=1
  retire_test_sources || rc=1
  if [ "$rc" -eq 0 ]; then
    rm -rf "$LAB" || rc=1
    [ "$rc" -ne 0 ] || LAB=''
  fi
  fm_test_cleanup
  return "$rc"
}
fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup || printf 'not ok - the exact test Lavish session could not be ended; its artifact was preserved at %s\n' "$LAB" >&2
  exit 1
}
trap 'cleanup || printf "not ok - Lavish test cleanup failed; artifact preserved at %s\\n" "$LAB" >&2' EXIT

VERSION=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
note "lavish-axi ${VERSION:-version-unknown}"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-bearings-lavish-live.XXXXXX") || fail "cannot create the guard lab"
LAB=$(cd -P -- "$LAB" && pwd -P)
mkdir -p "$LAB/state" "$LAB/data"

# The board builder invokes lavish-axi through plain PATH with an inherited
# environment, so exporting the provider's own suppression contract once covers
# every open this guard can reach.
export LAVISH_AXI_NO_OPEN=1

cat > "$LAB/payload.json" <<'JSON'
{
  "schema": "fm-bearings-board.v1",
  "home": "lavish-live-guard",
  "generated": "2026-01-01T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-live-guard-call",
      "type": "decision",
      "repo": "sample",
      "title": "Guard placeholder",
      "options": [{ "value": "yes", "label": "Yes" }]
    }
  ],
  "underway": [],
  "landed": [],
  "charted": []
}
JSON

run_board() {
  FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_DATA_OVERRIDE="$LAB/data" \
    FM_PROCEVENT_CLAIM_ROOT="$LAB/procevent-claims" \
    "$ROOT/bin/fm-bearings-board.sh" "$@"
}

BOARD="$LAB/.lavish/bearings-board.html"
run_board build "$LAB/payload.json" >/dev/null 2>&1 || fail "the guard board did not build"
[ -f "$BOARD" ] || fail "the guard board was not published"

url=$(lavish-axi "$BOARD" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
case "$url" in
  http://*/session/*) ;;
  *) fail "could not read the guard board session url: $url" ;;
esac
key=${url##*/}
base=${url%/session/*}

# End it exactly as the browser's End session button does.
curl -fsS -X POST "$base/api/$key/end" >/dev/null 2>&1 \
  || fail "could not end the guard board session as the captain"

# ASSUMPTION UNDER GUARD: this exits 0 while reporting the session is not live.
set +e
ended_out=$(lavish-axi "$BOARD" 2>&1)
ended_rc=$?
set -e
[ "$ended_rc" -eq 0 ] \
  || fail "lavish-axi ${VERSION:-version-unknown} now exits $ended_rc on a captain-ended session; the board build's liveness check must be revisited"
ended_status=$(printf '%s\n' "$ended_out" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"')
[ "$ended_status" != opened ] \
  || fail "lavish-axi ${VERSION:-version-unknown} silently reopened a captain-ended session; the board build's liveness check must be revisited"
lavish-axi 2>/dev/null | grep -F "$BOARD," | grep -q ',open,' \
  && fail "lavish-axi ${VERSION:-version-unknown} still lists a captain-ended session as open; the board build's liveness check must be revisited"
pass "lavish-axi ${VERSION:-version-unknown} reports a captain-ended session without reopening it and without failing"

# THE BEHAVIOR UNDER GUARD: the build must not accept that, and must recover.
out=$(run_board build "$LAB/payload.json" 2>&1) \
  || fail "the board build refused a recoverable captain-ended session: $out"
case "$out" in
  *"session: reopened"*) ;;
  *) fail "the board build did not reopen the captain-ended session: $out" ;;
esac
lavish-axi 2>/dev/null | grep -F "$BOARD," | grep -q ',open,' \
  || fail "the board build reported success while the session was still not live"
pass "the board build reopens a captain-ended session against real lavish-axi instead of arming a dead one"

end_test_session || fail "the exact guard board session did not end before artifact cleanup"
session_is_open && fail "the guard board session remained open after its exact end command"
SAVED_LAB=$LAB
cleanup || fail "the ended guard session's listener or temporary artifact could not be removed"
# The source runner is detached, so leave a short counterfactual window in
# which the pre-fix race recreated state/ after an eager rm -rf.
sleep 0.2
[ ! -e "$SAVED_LAB" ] || fail "the guard left or recreated its temporary artifact: $SAVED_LAB"
pass "the real provider contract left no open test session, listener, or temporary artifact"
