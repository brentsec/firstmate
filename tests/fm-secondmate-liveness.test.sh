#!/usr/bin/env bash
# tests/fm-secondmate-liveness.test.sh - the session-start secondmate liveness
# guarantee owned by bin/fm-backend.sh's detailed fm_backend_agent_state and
# bin/fm-bootstrap.sh's secondmate_liveness_sweep that acts on it.
#
# The gap under test (AGENTS.md "Session start"; evidence 2026-07-07): a
# secondmate agent that has exited leaves its backend endpoint alive as a bare
# shell. fm_backend_target_exists only checks pane PRESENCE, so it reports
# that shell "alive"; recovery only respawns endpoints reported dead, and the
# watcher deliberately exempts secondmates from stale-pane detection (an idle
# secondmate pane is healthy by design). A dead-shell secondmate was therefore
# invisible to every existing check and sat dead indefinitely.
#
# The guarantees under test:
#   - fm_backend_agent_state is the detailed owner that distinguishes alive,
#     dead, missing, ambiguous, unreadable, and unverified.
#   - The tmux classifier returns missing only after a readable session
#     inventory omits the exact window, regardless of display-message fallback.
#   - The Herdr classifier preserves the proven husk mapping while separating a
#     missing pane from an existing agent-less pane.
#   - fm_backend_agent_alive preserves the older three-state compatibility view.
#   - bin/fm-bootstrap.sh's secondmate_liveness_sweep fresh-spawns only dead or
#     missing endpoints, and replaces one attributed Herdr Claude process whose
#     exact argv lost the permission posture its own launch recorded (never one
#     that merely disagrees with an edited config) only on proof that its worker
#     is between turns - preserving and reporting a busy or unprovable one - then
#     reports every drift outcome unconditionally, keeps already-live results
#     silent by default, and reports ambiguous and unreadable targets distinctly.
#   - The sweep converges: once a secondmate reads alive, a later run never
#     re-touches it (idempotent by construction, not by remembering what it
#     already did).
#   - The sweep is skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1 (the
#     read-only session path), matching the other mutating sweeps.
#   - The sweep is naturally scoped to the primary: with no kind=secondmate
#     meta present (a secondmate's own state/ never holds one, since
#     secondmates never spawn secondmates), it is a silent no-op.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-secondmate-liveness)

# --- unit level: fm_backend_tmux_agent_state --------------------------------

# make_probe_tmux <dir> <pane_current_command>: a fake tmux whose
# #{pane_current_command} display-message query answers with the fixed value;
# every other subcommand is a silent no-op success.
make_probe_tmux() {
  local dir=$1 comm=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_command*) printf '%s\n' '$comm'; exit 0 ;; esac; done
    exit 0 ;;
  list-windows) printf '%s\n' win; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# make_failed_probe_tmux <dir> <inventory>: missing and present fail the pane
# read, while unreadable returns a misleading fallback node process but fails
# the inventory that must be authoritative.
make_failed_probe_tmux() {
  local dir=$1 inventory=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    [ '$inventory' = unreadable ] && { printf '%s\n' node; exit 0; }
    exit 1
    ;;
  list-windows)
    case '$inventory' in
      missing) printf '%s\n' main ; exit 0 ;;
      missing-session) printf '%s\n' "can't find session: sess" >&2; exit 1 ;;
      missing-server) printf '%s\n' "no server running on /tmp/tmux-test/default" >&2; exit 1 ;;
      missing-socket) printf '%s\n' "error connecting to /tmp/tmux-test/default (No such file or directory)" >&2; exit 1 ;;
      present) printf '%s\n' fm-sm1 ; exit 0 ;;
      *) printf '%s\n' "permission denied" >&2; exit 1 ;;
    esac
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_tmux_agent_state_classifies() {
  local fb out

  for harness in claude codex opencode grok kimi pi pi-signed pi-launcher Pi; do
    fb=$(make_probe_tmux "$TMP_ROOT/tmux-$harness" "$harness")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
    [ "$out" = alive ] || fail "a live $harness foreground process should classify as alive, got '$out'"
  done

  for shell in zsh bash -zsh; do
    fb=$(make_probe_tmux "$TMP_ROOT/tmux-${shell#-}" "$shell")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
    [ "$out" = dead ] || fail "a bare $shell foreground process should classify as dead, got '$out'"
  done

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-node" node)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
  [ "$out" = ambiguous ] || fail "an existing node process should classify as ambiguous, got '$out'"
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive tmux sess:win' "$ROOT")" = unknown ] \
    || fail "the compatibility view must keep an existing node process unknown"

  fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-missing" missing)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:fm-sm1' "$ROOT")
  [ "$out" = missing ] || fail "a readable inventory omitting the target should classify as missing, got '$out'"
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive tmux sess:fm-sm1' "$ROOT")" = dead ] \
    || fail "the compatibility view should treat an authoritatively missing target as dead"

  for inventory in present unreadable; do
    fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-$inventory" "$inventory")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:fm-sm1' "$ROOT")
    [ "$out" = unreadable ] || fail "a $inventory inventory case should stay unreadable, got '$out'"
  done

  for inventory in missing-session missing-server missing-socket; do
    fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-$inventory" "$inventory")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:fm-sm1' "$ROOT")
    [ "$out" = missing ] || fail "a confirmed $inventory inventory failure should classify as missing, got '$out'"
  done

  pass "fm_backend_tmux_agent_state: separates live, dead, missing, ambiguous, and unreadable"
}

test_tmux_agent_state_rejects_malformed_targets_before_probe() {
  local fakebin marker target out
  fakebin=$(fm_fakebin "$TMP_ROOT/tmux-malformed")
  marker="$TMP_ROOT/tmux-malformed-called"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'called\n' > "$FM_TEST_TMUX_MARKER"
printf 'bash\n'
SH
  chmod +x "$fakebin/tmux"

  for target in sess sess: :win sess:win:extra; do
    out=$(PATH="$fakebin:$BASE_PATH" FM_TEST_TMUX_MARKER="$marker" \
      bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux "$1"' "$ROOT" "$target")
    [ "$out" = unreadable ] || fail "malformed tmux target '$target' should classify as unreadable, got '$out'"
    [ ! -e "$marker" ] || fail "malformed tmux target '$target' invoked tmux"
  done

  pass "fm_backend_tmux_agent_state: rejects malformed targets before probing tmux"
}

# --- unit level: fm_backend_herdr_agent_state -------------------------------

test_herdr_agent_state_preserves_husk_classifier() {
  local pane_state expected out

  for row in 'dead missing' 'no-agent dead' 'live alive' 'unknown unreadable'; do
    pane_state=${row%% *}
    expected=${row#* }
    out=$(FM_TEST_PANE_STATE="$pane_state" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "%s" "$FM_TEST_PANE_STATE"; }; fm_backend_herdr_server_running_state() { printf running; }; fm_backend_herdr_agent_state "sess:p1"' "$ROOT")
    [ "$out" = "$expected" ] || fail "Herdr pane state $pane_state should map to $expected, got '$out'"
  done

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state "no-colon-target"' "$ROOT")
  [ "$out" = unreadable ] || fail "an unparseable Herdr target should classify as unreadable, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "no-agent"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = dead ] || fail "the Herdr compatibility view should keep a no-agent husk dead, got '$out'"

  pass "fm_backend_herdr_agent_state: preserves missing/no-agent/live/unknown husk behavior"
}

# --- unit level: the generic dispatchers ------------------------------------

test_agent_state_dispatcher_and_compatibility() {
  local fb out

  fb=$(make_probe_tmux "$TMP_ROOT/dispatch-tmux" claude)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
  [ "$out" = alive ] || fail "detailed dispatcher should route tmux, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_agent_state herdr sess:p1' "$ROOT")
  [ "$out" = alive ] || fail "detailed dispatcher should route Herdr, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state zellij sess:7' "$ROOT")
  [ "$out" = unverified ] || fail "Zellij should remain unverified, got '$out'"
  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive zellij sess:7' "$ROOT")
  [ "$out" = unknown ] || fail "the compatibility dispatcher should map unverified to unknown, got '$out'"

  pass "fm_backend_agent_state: routes tmux/Herdr and keeps Zellij unverified"
}

# --- sweep level: bin/fm-bootstrap.sh's secondmate_liveness_sweep -----------

# make_toolchain <dir>: the fixed set of stubs bin/fm-bootstrap.sh's read-only
# diagnostics need to stay quiet (mirrors tests/fm-secondmate-sync.test.sh's
# make_fake_toolchain), MINUS tmux - callers add their own controllable tmux.
make_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi pi-signed
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.4' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# make_liveness_tmux <dir>: a controllable tmux stub. FM_TEST_PANE_CMD may be
# a foreground command, `missing` (readable inventory omits the window), or
# `unreadable` (both pane and inventory reads fail).
make_liveness_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_TEST_PANE_CMD:-zsh}
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*)
          case "$mode" in
            missing) printf '%s\n' node; exit 0 ;;
            unreadable) exit 1 ;;
            *) printf '%s\n' "$mode"; exit 0 ;;
          esac
          ;;
      esac
    done
    exit 0
    ;;
  list-windows)
    case "$mode" in
      missing) printf '%s\n' main; exit 0 ;;
      unreadable) exit 1 ;;
      *) [ -e "${FM_TMUX_CALL_LOG:?}.killed" ] || printf '%s\n' fm-sm1; exit 0 ;;
    esac
    ;;
  new-window|kill-window)
    printf '%s\n' "$*" >> "${FM_TMUX_CALL_LOG:?}"
    [ "${1:-}" = kill-window ] && : > "${FM_TMUX_CALL_LOG}.killed"
    [ "${FM_TEST_FAIL_NEW_WINDOW:-0}" = 1 ] && [ "${1:-}" = new-window ] && exit 1
    [ "${1:-}" = new-window ] && rm -f "${FM_TMUX_CALL_LOG}.killed"
    exit 0
    ;;
  has-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# make_liveness_herdr <dir>: a process-info fixture for the exact restored
# Claude states the Herdr adapter exposes to the bootstrap sweep. The generic
# pane-liveness pass and policy pass both read the same foreground process set,
# whose group leader (pid 4101, the pane's foreground job) is the top-level
# worker posture attribution anchors on; 4102 is a claude CLI that worker runs
# from its own shell tool.
make_liveness_herdr() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_TEST_HERDR_CLAUDE_STATE:-drift}
pane=${FM_TEST_HERDR_PANE_ID:-w1:p1}
case "${1:-} ${2:-}" in
  "pane get")
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$pane"
    ;;
  "agent get")
    printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n'
    ;;
  "pane process-info")
    case "$mode" in
      drift)
        foreground='[{"pid":4101,"name":"claude","argv0":"claude","argv":["claude","--resume","restored-session"]}]'
        ;;
      alive)
        foreground='[{"pid":4101,"name":"claude","argv0":"claude","argv":["claude","--dangerously-skip-permissions","--resume","restored-session"]}]'
        ;;
      ambiguous)
        foreground='[{"pid":4101,"name":"claude","argv0":"claude","argv":["claude","--resume","restored-session","--dangerously-skip-permissions","--permission-mode","auto"]}]'
        ;;
      nested)
        foreground='[{"pid":4101,"name":"claude","argv0":"claude","argv":["claude","--dangerously-skip-permissions","--resume","restored-session"]},{"pid":4102,"name":"claude","argv0":"claude","argv":["claude","-p","summarize the diff"]}]'
        ;;
      drift-nested)
        foreground='[{"pid":4102,"name":"claude","argv0":"claude","argv":["claude","--dangerously-skip-permissions","--version"]},{"pid":4101,"name":"claude","argv0":"claude","argv":["claude","--resume","restored-session"]}]'
        ;;
      *) exit 1 ;;
    esac
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":4101,"foreground_processes":%s}}}\n' \
      "$pane" "$$" "$foreground"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

# write_recovery_stubs <root>: replace exactly the two replacement routes the
# sweep can reach, so a run shows which one it chose and what it reported.
#   fm-control.sh - the same-task local relaunch, the only route a locally
#     placed live mate may be replaced through. Its exit status is selectable
#     so the sweep's honest failure report is observable too.
#   fm-spawn.sh - the fresh-spawn/remote route. It deliberately fails by
#     default, so a local drift that reaches it is visible as the wrong choice;
#     a remote test that legitimately expects it sets FM_TEST_SPAWN_RC=0.
write_recovery_stubs() {
  local root=$1
  cat > "$root/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_CONTROL_LOG:?}"
[ -z "${FM_TEST_CONTROL_OUT:-}" ] || printf '%s\n' "$FM_TEST_CONTROL_OUT"
exit "${FM_TEST_CONTROL_RC:-0}"
SH
  cat > "$root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_SPAWN_LOG:?}"
exit "${FM_TEST_SPAWN_RC:-91}"
SH
  chmod +x "$root/bin/fm-control.sh" "$root/bin/fm-spawn.sh"
}

# arm_busy_state <state-dir> <id> <busy|idle>: put the mate's semantic turn
# state on disk through bin/fm-busy-event.sh, the contract's only writer, so
# the sweep reads it back through the real classifier.
arm_busy_state() {
  local state=$1 id=$2 want=$3
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" \
    --state "$want" --source fm-spawn --event launch-brief >/dev/null
}

# make_control_probe_root <dir>: an exact copy of the public bootstrap tree with
# only those recovery entry points replaced, so the routing decision a run
# observes is the sweep's real one.
make_control_probe_root() {
  local dir=$1 root
  root="$dir/runtime-root"
  mkdir -p "$root"
  cp -R "$ROOT/bin" "$root/bin"
  printf '# Firstmate fixture\n' > "$root/AGENTS.md"
  write_recovery_stubs "$root"
  printf '%s\n' "$root"
}

# A remote liveness check calls the route-local fm-on sibling, so the same copy
# additionally replaces that transport boundary. The stub records every remote
# request and returns the selected state.
make_remote_control_probe_root() {
  local dir=$1 root
  root="$dir/remote-runtime-root"
  mkdir -p "$root"
  cp -R "$ROOT/bin" "$root/bin"
  printf '# Firstmate fixture\n' > "$root/AGENTS.md"
  write_recovery_stubs "$root"
  cat > "$root/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_REMOTE_CALL_LOG:?}"
case "$*" in
  "sm1 fm-remote-doctor.sh") exit 0 ;;
  "sm1 fm-remote-secondmate-control.sh state sm1")
    printf '%s\n' "${FM_TEST_REMOTE_AGENT_STATE:-permission-drift}"
    ;;
  "sm1 fm-remote-secondmate-control.sh observe sm1")
    printf '%s\n' "${FM_TEST_REMOTE_OBSERVE:-idle}"
    ;;
  "sm1 fm-remote-secondmate-control.sh relaunch sm1 "*) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$root/bin/fm-on.sh"
  printf '%s\n' "$root"
}

# new_world <name>: a scratch firstmate HOME (state/, watcher beacon, pinned
# harness) with no kind=secondmate meta yet. FM_ROOT is left to resolve
# naturally to the real checkout under test ($ROOT), exactly as production
# always has it - this sweep's own fm-spawn.sh invocation resolves the
# secondmate harness through $FM_ROOT/bin/fm-harness.sh, which only exists in
# the real tree. The harness is pinned because ambient own-harness detection is
# environment-dependent: interactive harness sessions expose markers or parent
# process names, while a plain pipeline shell can fall through to "unknown",
# which has no fm-spawn.sh launch template.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf '%s\n' "$w"
}

# add_sm_home <w> <id> <window>: a plain (non-git) secondmate home - the
# probe/respawn machinery under test never requires the home to be a real
# worktree; a non-git home just makes the unrelated fast-forward sweep log a
# harmless "not a git repo" skip.
add_sm_home() {
  local w=$1 id=$2 window=$3 harness=${4:-claude}
  local home="$w/$id"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  {
    printf 'window=%s\n' "$window"
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    printf 'home=%s\n' "$home"
  } > "$w/home/state/$id.meta"
}

run_bootstrap() {  # <fakebin> <home> <pane-cmd> <call-log> [extra env...] -> stdout
  local fb=$1 home=$2 cmd=$3 log=$4; shift 4
  PATH="$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$home" \
    FM_TEST_PANE_CMD="$cmd" FM_TMUX_CALL_LOG="$log" \
    env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

# Same run, executed from a probe root's own copy of the tree so every sibling
# script the sweep reaches for is that copy's.
run_bootstrap_from() {  # <root> <fakebin> <home> <pane-cmd> <call-log> [extra env...] -> stdout
  local root=$1 fb=$2 home=$3 cmd=$4 log=$5; shift 5
  PATH="$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$root" FM_TEST_PANE_CMD="$cmd" FM_TMUX_CALL_LOG="$log" \
    env "$@" "$root/bin/fm-bootstrap.sh" 2>&1
}

test_sweep_respawns_confirmed_dead_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-dead)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawned" \
    "a successfully respawned secondmate should be handled silently"
  assert_contains "$(cat "$log")" "kill-window -t =firstmate:=fm-sm1" \
    "the stale endpoint must be killed before respawn (tmux refuses a same-named window over a live one)"
  assert_contains "$(cat "$log")" "new-window" \
    "a confirmed-dead secondmate should actually be relaunched"
  pass "sweep: a confirmed-dead secondmate endpoint is killed and respawned"
}

test_sweep_leaves_alive_secondmate_untouched() {
  local w fb tmuxfb log out
  w=$(new_world sweep-alive)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: already-live" \
    "an already-live secondmate should be handled silently"
  [ ! -s "$log" ] || fail "an already-live secondmate must never be killed or respawned: $(cat "$log")"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log" FM_BOOTSTRAP_VERBOSE_FACTS=1)
  assert_contains "$out" "BOOTSTRAP_INFO: secondmate sm1 already live (backend=tmux)" \
    "verbose diagnostics should identify the already-live outcome"
  [ ! -s "$log" ] || fail "verbose reporting must not touch an already-live secondmate: $(cat "$log")"
  pass "sweep: an already-live secondmate is untouched and distinguishable in verbose diagnostics"
}

# A drifted worker is the one live population this sweep may replace, and it may
# only do so on proof that the worker is between turns. A recorded idle is that
# proof, and the replacement is the same-task control relaunch, never a fresh
# spawn - and the captain is told it happened, because the endpoint record any
# earlier digest printed is now superseded.
test_sweep_replaces_a_proven_idle_drifted_claude_in_place() {
  local w fb tmuxfb herdrfb root log spawn_log out
  w=$(new_world sweep-claude-permission-drift)
  add_sm_home "$w" sm1 lab:w1:p1 claude
  printf 'backend=herdr\nspawn_gen=g7\nclaude_permission_mode=bypass\n' >> "$w/home/state/sm1.meta"
  printf 'claude\n' > "$w/home/config/secondmate-harness"
  arm_busy_state "$w/home/state" sm1 idle
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w"); herdrfb=$(make_liveness_herdr "$w")
  root=$(make_control_probe_root "$w")
  log="$w/control.log"; spawn_log="$w/spawn.log"; : > "$log"; : > "$spawn_log"

  out=$(run_bootstrap_from "$root" "$herdrfb:$tmuxfb:$fb" "$w/home" claude "$w/tmux.log" \
    FM_TEST_HERDR_CLAUDE_STATE=drift FM_TEST_HERDR_PANE_ID=w1:p1 \
    FM_TEST_CONTROL_LOG="$log" FM_TEST_SPAWN_LOG="$spawn_log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: relaunched after the live Claude process lacks the permission posture its launch recorded (backend=herdr)" \
    "replacing a live worker must be reported, never left to a verbose-only fact"
  [ "$(cat "$log")" = "sm1 relaunch" ] \
    || fail "a proven-idle permission drift did not use the same-task control relaunch: $(cat "$log")"
  [ ! -s "$spawn_log" ] \
    || fail "permission drift used the fresh-spawn path instead of preserving the exact endpoint and copy"
  pass "sweep: a proven-idle Claude permission drift is relaunched in place and reported"
}

# The other side of that proof: a worker mid-turn, and a worker whose turn state
# this home cannot prove at all, are both left running. Neither may be stopped on
# a guess, and both are reported with the command that owns the supervised
# replacement, so the drift never disappears silently.
test_sweep_preserves_a_drifted_claude_it_cannot_prove_is_between_turns() {
  local w fb tmuxfb herdrfb root log spawn_log out
  w=$(new_world sweep-claude-drift-preserved)
  add_sm_home "$w" sm1 lab:w1:p1 claude
  printf 'backend=herdr\nspawn_gen=g7\nclaude_permission_mode=bypass\n' >> "$w/home/state/sm1.meta"
  printf 'claude\n' > "$w/home/config/secondmate-harness"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w"); herdrfb=$(make_liveness_herdr "$w")
  root=$(make_control_probe_root "$w")
  log="$w/control.log"; spawn_log="$w/spawn.log"; : > "$log"; : > "$spawn_log"

  arm_busy_state "$w/home/state" sm1 busy
  out=$(run_bootstrap_from "$root" "$herdrfb:$tmuxfb:$fb" "$w/home" claude "$w/tmux.log" \
    FM_TEST_HERDR_CLAUDE_STATE=drift FM_TEST_HERDR_PANE_ID=w1:p1 \
    FM_TEST_CONTROL_LOG="$log" FM_TEST_SPAWN_LOG="$spawn_log")
  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: the live Claude process lacks the permission posture its launch recorded, and its worker is mid-turn, so it was left running; replace it under supervision with bin/fm-control.sh sm1 relaunch (backend=herdr)" \
    "a mid-turn drifted worker must be preserved and reported with its supervised route"
  [ ! -s "$log" ] && [ ! -s "$spawn_log" ] \
    || fail "a mid-turn drifted worker was stopped anyway: control=$(cat "$log") spawn=$(cat "$spawn_log")"

  rm -f "$w/home/state/sm1.busy-state" "$w/home/state/sm1.busy-gen"
  out=$(run_bootstrap_from "$root" "$herdrfb:$tmuxfb:$fb" "$w/home" claude "$w/tmux.log" \
    FM_TEST_HERDR_CLAUDE_STATE=drift FM_TEST_HERDR_PANE_ID=w1:p1 \
    FM_TEST_CONTROL_LOG="$log" FM_TEST_SPAWN_LOG="$spawn_log")
  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: the live Claude process lacks the permission posture its launch recorded, and this home cannot prove its worker is between turns, so it was left running; replace it under supervision with bin/fm-control.sh sm1 relaunch (backend=herdr)" \
    "an unprovable turn state must never be promoted to idle"
  [ ! -s "$log" ] && [ ! -s "$spawn_log" ] \
    || fail "a drifted worker with no turn-state proof was stopped anyway: control=$(cat "$log") spawn=$(cat "$spawn_log")"
  pass "sweep: a busy or unprovable drifted worker is left running and reported for supervised replacement"
}

# A replacement that was attempted and failed is NOT an untouched mate: the old
# worker was already stopped, so the report must not reuse the left-running
# wording that tells the captain the endpoint is still good.
test_sweep_reports_a_failed_drift_replacement_as_a_failure() {
  local w fb tmuxfb herdrfb root log spawn_log out
  w=$(new_world sweep-claude-drift-failed)
  add_sm_home "$w" sm1 lab:w1:p1 claude
  printf 'backend=herdr\nspawn_gen=g7\nclaude_permission_mode=bypass\n' >> "$w/home/state/sm1.meta"
  printf 'claude\n' > "$w/home/config/secondmate-harness"
  arm_busy_state "$w/home/state" sm1 idle
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w"); herdrfb=$(make_liveness_herdr "$w")
  root=$(make_control_probe_root "$w")
  log="$w/control.log"; spawn_log="$w/spawn.log"; : > "$log"; : > "$spawn_log"

  out=$(run_bootstrap_from "$root" "$herdrfb:$tmuxfb:$fb" "$w/home" claude "$w/tmux.log" \
    FM_TEST_HERDR_CLAUDE_STATE=drift FM_TEST_HERDR_PANE_ID=w1:p1 \
    FM_TEST_CONTROL_LOG="$log" FM_TEST_SPAWN_LOG="$spawn_log" \
    FM_TEST_CONTROL_RC=1 FM_TEST_CONTROL_OUT="error: the replacement never came up")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: relaunch failed after the live Claude process lacks the permission posture its launch recorded: error: the replacement never came up" \
    "a failed replacement must be reported as a failure with its reason"
  assert_not_contains "$out" "so it was left running" \
    "a stopped-then-failed worker must never be reported as still running"
  assert_not_contains "$out" "relaunched after" \
    "a failed replacement must never be reported as completed"
  pass "sweep: a drift replacement that was attempted and failed is reported as a failure, not as an untouched mate"
}

test_sweep_refuses_ambiguous_restored_claude_processes() {
  local w fb tmuxfb herdrfb root log spawn_log out
  w=$(new_world sweep-claude-permission-ambiguous)
  add_sm_home "$w" sm1 lab:w1:p1 claude
  printf 'backend=herdr\nspawn_gen=g7\nclaude_permission_mode=bypass\n' >> "$w/home/state/sm1.meta"
  printf 'claude\n' > "$w/home/config/secondmate-harness"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w"); herdrfb=$(make_liveness_herdr "$w")
  root=$(make_control_probe_root "$w")
  log="$w/control.log"; spawn_log="$w/spawn.log"; : > "$log"; : > "$spawn_log"

  out=$(run_bootstrap_from "$root" "$herdrfb:$tmuxfb:$fb" "$w/home" claude "$w/tmux.log" \
    FM_TEST_HERDR_CLAUDE_STATE=ambiguous FM_TEST_HERDR_PANE_ID=w1:p1 \
    FM_TEST_CONTROL_LOG="$log" FM_TEST_SPAWN_LOG="$spawn_log")

  assert_contains "$out" "skipped: existing endpoint has ambiguous agent process" \
    "a top-level Claude process carrying both permission flags should be reported as ambiguous"
  [ ! -s "$log" ] && [ ! -s "$spawn_log" ] \
    || fail "an ambiguous restored Claude posture triggered lifecycle work"
  pass "sweep: an ambiguous restored Claude posture refuses every automatic recovery action"
}

# A worker's own shell tool may run a nested claude CLI inside the pane's
# foreground group. It is a descendant of the attributed worker, never the
# worker, so the sweep leaves a conforming worker alone beside it and still
# relaunches a genuinely drifted worker beside a conforming child.
test_sweep_ignores_a_nested_claude_cli_under_a_conforming_worker() {
  local w fb tmuxfb herdrfb root log spawn_log out
  w=$(new_world sweep-claude-nested-cli)
  add_sm_home "$w" sm1 lab:w1:p1 claude
  printf 'backend=herdr\nspawn_gen=g7\nclaude_permission_mode=bypass\n' >> "$w/home/state/sm1.meta"
  printf 'claude\n' > "$w/home/config/secondmate-harness"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w"); herdrfb=$(make_liveness_herdr "$w")
  root=$(make_control_probe_root "$w")
  log="$w/control.log"; spawn_log="$w/spawn.log"; : > "$log"; : > "$spawn_log"

  out=$(run_bootstrap_from "$root" "$herdrfb:$tmuxfb:$fb" "$w/home" claude "$w/tmux.log" \
    FM_TEST_HERDR_CLAUDE_STATE=nested FM_TEST_HERDR_PANE_ID=w1:p1 \
    FM_TEST_CONTROL_LOG="$log" FM_TEST_SPAWN_LOG="$spawn_log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "a conforming worker running a nested claude CLI must read as plainly alive"
  [ ! -s "$log" ] && [ ! -s "$spawn_log" ] \
    || fail "a nested claude CLI under a conforming worker triggered lifecycle work: $(cat "$log" "$spawn_log")"
  pass "sweep: a nested claude CLI under a conforming worker is never drift or ambiguity"
}

test_sweep_relaunches_top_level_drift_beside_a_nested_conforming_claude() {
  local w fb tmuxfb herdrfb root log spawn_log out
  w=$(new_world sweep-claude-drift-nested)
  add_sm_home "$w" sm1 lab:w1:p1 claude
  printf 'backend=herdr\nspawn_gen=g7\nclaude_permission_mode=bypass\n' >> "$w/home/state/sm1.meta"
  printf 'claude\n' > "$w/home/config/secondmate-harness"
  arm_busy_state "$w/home/state" sm1 idle
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w"); herdrfb=$(make_liveness_herdr "$w")
  root=$(make_control_probe_root "$w")
  log="$w/control.log"; spawn_log="$w/spawn.log"; : > "$log"; : > "$spawn_log"

  out=$(run_bootstrap_from "$root" "$herdrfb:$tmuxfb:$fb" "$w/home" claude "$w/tmux.log" \
    FM_TEST_HERDR_CLAUDE_STATE=drift-nested FM_TEST_HERDR_PANE_ID=w1:p1 \
    FM_TEST_CONTROL_LOG="$log" FM_TEST_SPAWN_LOG="$spawn_log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: relaunched after the live Claude process lacks the permission posture its launch recorded (backend=herdr)" \
    "a completed replacement of a drifted worker must be reported"
  [ "$(cat "$log")" = "sm1 relaunch" ] \
    || fail "top-level drift beside a nested conforming claude CLI did not relaunch in place: $(cat "$log")"
  [ ! -s "$spawn_log" ] \
    || fail "top-level drift took the fresh-spawn route: $(cat "$spawn_log")"
  pass "sweep: genuine top-level drift still replaces the worker beside a nested conforming claude CLI"
}

# The expectation is the recorded launch, not the current file: editing
# config/claude-permission-mode while the fleet runs must not make the sweep
# replace a worker that still carries exactly the posture it was launched with.
test_sweep_leaves_a_correctly_launched_worker_alone_after_a_config_edit() {
  local w fb tmuxfb herdrfb root log spawn_log out
  w=$(new_world sweep-claude-config-edit)
  add_sm_home "$w" sm1 lab:w1:p1 claude
  printf 'backend=herdr\nspawn_gen=g7\nclaude_permission_mode=bypass\n' >> "$w/home/state/sm1.meta"
  printf 'claude\n' > "$w/home/config/secondmate-harness"
  printf 'auto\n' > "$w/home/config/claude-permission-mode"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w"); herdrfb=$(make_liveness_herdr "$w")
  root=$(make_control_probe_root "$w")
  log="$w/control.log"; spawn_log="$w/spawn.log"; : > "$log"; : > "$spawn_log"

  out=$(run_bootstrap_from "$root" "$herdrfb:$tmuxfb:$fb" "$w/home" claude "$w/tmux.log" \
    FM_TEST_HERDR_CLAUDE_STATE=alive FM_TEST_HERDR_PANE_ID=w1:p1 \
    FM_TEST_CONTROL_LOG="$log" FM_TEST_SPAWN_LOG="$spawn_log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "a worker still carrying its recorded posture must stay silent after a config edit"
  [ ! -s "$log" ] && [ ! -s "$spawn_log" ] \
    || fail "a config edit alone replaced a correctly launched running worker: control=$(cat "$log") spawn=$(cat "$spawn_log")"
  pass "sweep: a config edit changes only the next launch and never relaunches a conforming worker"
}

# A record written before the launch posture existed carries no conclusive
# expectation, so even a restored-looking argv is not drift: the generic live
# reading stands until the next Firstmate-owned launch records one.
test_sweep_needs_a_recorded_posture_before_calling_drift() {
  local w fb tmuxfb herdrfb root log spawn_log out
  w=$(new_world sweep-claude-unrecorded)
  add_sm_home "$w" sm1 lab:w1:p1 claude
  printf 'backend=herdr\nspawn_gen=g7\n' >> "$w/home/state/sm1.meta"
  printf 'claude\n' > "$w/home/config/secondmate-harness"
  printf 'bypass\n' > "$w/home/config/claude-permission-mode"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w"); herdrfb=$(make_liveness_herdr "$w")
  root=$(make_control_probe_root "$w")
  log="$w/control.log"; spawn_log="$w/spawn.log"; : > "$log"; : > "$spawn_log"

  out=$(run_bootstrap_from "$root" "$herdrfb:$tmuxfb:$fb" "$w/home" claude "$w/tmux.log" \
    FM_TEST_HERDR_CLAUDE_STATE=drift FM_TEST_HERDR_PANE_ID=w1:p1 \
    FM_TEST_CONTROL_LOG="$log" FM_TEST_SPAWN_LOG="$spawn_log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "an unrecorded posture must not produce a liveness diagnostic"
  [ ! -s "$log" ] && [ ! -s "$spawn_log" ] \
    || fail "a record with no launch posture was relaunched from the current config: control=$(cat "$log") spawn=$(cat "$spawn_log")"
  pass "sweep: drift needs a recorded launch posture, never the current config alone"
}

# Placement changes the transport of both halves, never the rule: a drifted
# remote mate is just as live as a local one, so it is replaced only on the
# host's own proof that its worker is between turns, and then through the one
# validated remote route the dead and missing endpoints already use. A busy or
# unreadable observation preserves the worker, and ambiguity still licenses
# nothing at all.
test_remote_sweep_relaunches_drift_and_refuses_ambiguity() {
  local w fb tmuxfb root remote_log spawn_log out
  w=$(new_world sweep-remote-claude-permission)
  add_sm_home "$w" sm1 remote:sm1 claude
  cat >> "$w/home/state/sm1.meta" <<'EOF'
remote_host=remote.test
remote_root=/srv/firstmate
remote_backend=herdr
remote_target=fm-remote:w1:p1
EOF
  printf 'claude\n' > "$w/home/config/secondmate-harness"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  root=$(make_remote_control_probe_root "$w")
  remote_log="$w/remote.log"; spawn_log="$w/spawn.log"

  remote_drift_sweep() {  # <extra env...>
    : > "$remote_log"; : > "$spawn_log"
    PATH="$tmuxfb:$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$w/home" \
      FM_ROOT_OVERRIDE="$root" FM_TEST_REMOTE_CALL_LOG="$remote_log" \
      FM_TEST_SPAWN_LOG="$spawn_log" FM_TEST_CONTROL_LOG="$w/control.log" \
      env "$@" "$root/bin/fm-bootstrap.sh" 2>&1
  }

  out=$(remote_drift_sweep FM_TEST_REMOTE_AGENT_STATE=permission-drift \
    FM_TEST_REMOTE_OBSERVE=idle FM_TEST_SPAWN_RC=0)
  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: relaunched after the live Claude process lacks the permission posture its launch recorded (host=remote.test)" \
    "a completed remote replacement must be reported"
  [ "$(cat "$spawn_log")" = "sm1 --secondmate" ] \
    || fail "remote permission drift did not use the one validated remote recovery route: $(cat "$spawn_log")"
  grep -F "fm-remote-secondmate-control.sh relaunch" "$remote_log" >/dev/null \
    && fail "the sweep crossed the transport itself instead of using the remote recovery route"

  out=$(remote_drift_sweep FM_TEST_REMOTE_AGENT_STATE=permission-drift \
    FM_TEST_REMOTE_OBSERVE=busy FM_TEST_SPAWN_RC=0)
  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: the live Claude process lacks the permission posture its launch recorded, and its worker is mid-turn, so it was left running; replace it under supervision with bin/fm-spawn.sh sm1 --secondmate (host=remote.test)" \
    "a mid-turn remote worker must be preserved and reported with its supervised route"
  [ ! -s "$spawn_log" ] || fail "a mid-turn remote worker was replaced anyway: $(cat "$spawn_log")"

  out=$(remote_drift_sweep FM_TEST_REMOTE_AGENT_STATE=permission-drift \
    FM_TEST_REMOTE_OBSERVE=fallback-idle FM_TEST_SPAWN_RC=0)
  assert_contains "$out" "and this home cannot prove its worker is between turns, so it was left running; replace it under supervision with bin/fm-spawn.sh sm1 --secondmate (host=remote.test)" \
    "a weak rendered idle must never be promoted to proof that the worker is between turns"
  [ ! -s "$spawn_log" ] || fail "a weak rendered idle replaced the remote worker: $(cat "$spawn_log")"

  out=$(remote_drift_sweep FM_TEST_REMOTE_AGENT_STATE=ambiguous FM_TEST_SPAWN_RC=0)
  assert_contains "$out" "skipped: remote endpoint state is ambiguous on remote.test" \
    "a remote ambiguous Claude posture should be reported as ambiguous"
  grep -F "fm-remote-secondmate-control.sh observe" "$remote_log" >/dev/null \
    && fail "remote ambiguity paid for a turn-state observation it may not act on"
  [ ! -s "$spawn_log" ] || fail "remote ambiguity triggered a replacement"
  pass "remote sweep: a drifted Claude is replaced only on the host's own proof it is between turns, while ambiguity refuses lifecycle work"
}

# The captain's documented remote recovery entry point is fm-spawn --secondmate,
# which reaches the host-local `launch` verb. Now that verb resolves the
# recovery-grade state, a restored Claude that lost its recorded posture arrives
# as permission-drift. That is one attributed process, not a duplicate to refuse:
# it is exactly what the sibling relaunch verb repairs, so launch must route it
# there. Ambiguity - which licenses no lifecycle action anywhere - still refuses.
#
# The control script's own dispatch is executed; only the backend verdict and the
# replacement leg are replaced, so the routing decision under test is the real one.
test_remote_launch_recovers_permission_drift_and_still_refuses_ambiguity() {
  local w home log outfile out rc
  w=$(new_world remote-launch-drift)
  home="$w/remote-home"
  mkdir -p "$home/bin" "$home/state/parent-route"
  printf 'sm1\n' > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  : > "$home/state/parent-route/sm1.meta"
  log="$w/relaunch.log"; : > "$log"
  outfile="$w/launch.out"

  # Not a command substitution: the exit status of the launch under test is the
  # assertion, and a subshell would not carry it back.
  exercise_remote_launch() {  # <state>; writes $outfile, sets rc
    rc=0
    FM_HOME="$home" FM_TEST_STATE="$1" FM_TEST_RELAUNCH_LOG="$log" bash -c '
      . "$1" state sm1 >/dev/null 2>&1
      fm_backend_agent_state_for_meta() { printf "%s" "$FM_TEST_STATE"; }
      remote_endpoint_require() { REMOTE_ENDPOINT_META="$FM_HOME/state/parent-route/$1.meta"; }
      cmd_relaunch() { printf "relaunch %s\n" "$*" >> "$FM_TEST_RELAUNCH_LOG"; }
      print_route() { printf "route=%s\n" "$1"; }
      cmd_launch sm1 claude - - herdr
    ' _ "$ROOT/bin/fm-remote-secondmate-control.sh" > "$outfile" 2>&1 || rc=$?
    out=$(cat "$outfile")
  }

  exercise_remote_launch permission-drift
  [ "$rc" = 0 ] || fail "a drifted remote mate must be recovered, not refused (rc $rc): $out"
  assert_contains "$(cat "$log")" "relaunch sm1 claude - -" \
    "remote launch did not route permission drift through the relaunch verb"
  assert_contains "$out" "route=sm1" "a recovered remote launch did not print its route"

  : > "$log"
  exercise_remote_launch ambiguous
  [ "$rc" != 0 ] || fail "an ambiguous remote endpoint must refuse the launch: $out"
  [ ! -s "$log" ] || fail "remote ambiguity triggered a relaunch: $(cat "$log")"

  : > "$log"
  exercise_remote_launch unreadable
  [ "$rc" != 0 ] || fail "an unreadable remote endpoint must refuse the launch: $out"
  [ ! -s "$log" ] || fail "an unreadable remote endpoint triggered a relaunch: $(cat "$log")"

  unset -f exercise_remote_launch
  pass "remote launch: proven permission drift recovers through relaunch while ambiguity and unreadability refuse"
}

test_sweep_respawns_authoritatively_missing_pi_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-missing-pi)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" "a successful missing-window recovery should stay silent by default"
  assert_contains "$(cat "$log")" "new-window" "an authoritatively missing Pi secondmate should be relaunched"
  assert_not_contains "$(cat "$log")" "kill-window" "an absent window should not need a destructive pre-kill"
  pass "sweep: an authoritatively missing Pi secondmate window is relaunched"
}

test_sweep_respawns_authoritatively_missing_pi_signed_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-missing-pi-signed)
  printf '%s\n' pi-signed > "$w/home/config/secondmate-harness"
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi-signed
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log")

  assert_not_contains "$out" "unverified for recovery" \
    "a recorded pi-signed secondmate should be verified for recovery"
  assert_contains "$(cat "$log")" "new-window" \
    "an authoritatively missing pi-signed secondmate should be relaunched"
  assert_not_contains "$(cat "$log")" "kill-window" \
    "an absent pi-signed window should not need a destructive pre-kill"
  pass "sweep: an authoritatively missing pi-signed secondmate window is relaunched"
}

test_sweep_never_acts_on_ambiguous_existing_process() {
  local w fb tmuxfb log out
  w=$(new_world sweep-ambiguous)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" node "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: existing endpoint has ambiguous agent process" \
    "an existing Pi-shaped node process should be reported as ambiguous"
  [ ! -s "$log" ] || fail "an ambiguous existing process must never trigger kill or relaunch: $(cat "$log")"
  pass "sweep: an existing ambiguous Pi process prevents duplicate recovery"
}

test_sweep_never_acts_on_transient_unreadability() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unreadable)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" unreadable "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: endpoint probe unreadable" \
    "a transiently unreadable target should be distinguished from an absent one"
  [ ! -s "$log" ] || fail "an unreadable target must never trigger kill or relaunch: $(cat "$log")"
  pass "sweep: transient target unreadability never licenses recovery"
}

test_sweep_reports_missing_endpoint_relaunch_failure() {
  local w fb tmuxfb log out
  w=$(new_world sweep-missing-failure)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log" FM_TEST_FAIL_NEW_WINDOW=1)

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawn failed after recorded endpoint confidently missing" \
    "a failed missing-endpoint relaunch should retain its authorizing cause"
  pass "sweep: failed relaunch diagnostics distinguish a confidently missing endpoint"
}

test_sweep_never_acts_on_unverified_harness_dead_reading() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unverified-harness)
  add_sm_home "$w" sm1 firstmate:fm-sm1 custom-agent
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: recorded harness 'custom-agent' is unverified for recovery" \
    "an unverified harness should not let a dead endpoint become actionable"
  [ ! -s "$log" ] || fail "an unverified harness must never trigger kill or relaunch: $(cat "$log")"
  pass "sweep: an unverified harness blocks recovery with a concrete diagnostic"
}

test_sweep_converges_no_retouch_once_alive() {
  local w fb tmuxfb log out1 out2
  w=$(new_world sweep-idempotent)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # Round 1: dead -> respawned silently (kill + new-window logged).
  out1=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
  assert_not_contains "$out1" "SECONDMATE_LIVENESS: secondmate sm1: respawned" "round 1 should handle the successful respawn silently"
  [ -s "$log" ] || fail "round 1 should have logged the kill+respawn window operations"

  # Round 2: the (now-respawned) secondmate is genuinely alive - a second
  # sweep must converge to a pure no-op, not respawn again.
  : > "$log"
  out2=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")
  assert_not_contains "$out2" "SECONDMATE_LIVENESS: secondmate sm1: already-live" "round 2 should handle the already-live secondmate silently"
  [ ! -s "$log" ] || fail "round 2 must not re-kill or re-respawn an already-live secondmate: $(cat "$log")"
  pass "sweep: idempotent by construction - a live secondmate is never re-touched on a later run"
}

test_sweep_skipped_under_detect_only() {
  local w fb tmuxfb log out
  w=$(new_world sweep-detect-only)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  mkdir -p "$w/home/config"
  printf 'codex\n' > "$w/home/config/crew-harness"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" FM_BOOTSTRAP_DETECT_ONLY=1)

  assert_not_contains "$out" "CREW_HARNESS_OVERRIDE:" \
    "detect-only should keep routine harness facts silent"
  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "the read-only detect-only path must never run the mutating liveness sweep"
  [ ! -s "$log" ] || fail "detect-only must never touch any endpoint: $(cat "$log")"
  pass "sweep: skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1, exactly like the other mutating sweeps"
}

test_sweep_noop_with_no_secondmate_meta() {
  local w fb tmuxfb log out
  w=$(new_world sweep-no-secondmates)
  # No add_sm_home call: this state/ dir looks exactly like what a
  # secondmate's OWN home always has (secondmates never spawn secondmates),
  # proving the sweep's primary-only scoping falls out naturally.
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "with no kind=secondmate meta present, the sweep must print nothing"
  [ ! -s "$log" ] || fail "with no secondmate meta, no endpoint should ever be touched: $(cat "$log")"
  pass "sweep: a silent no-op with no kind=secondmate meta present (a secondmate home's own natural scoping)"
}

test_tmux_agent_state_classifies
test_tmux_agent_state_rejects_malformed_targets_before_probe
test_herdr_agent_state_preserves_husk_classifier
test_agent_state_dispatcher_and_compatibility
test_sweep_respawns_confirmed_dead_secondmate
test_sweep_leaves_alive_secondmate_untouched
test_sweep_replaces_a_proven_idle_drifted_claude_in_place
test_sweep_preserves_a_drifted_claude_it_cannot_prove_is_between_turns
test_sweep_reports_a_failed_drift_replacement_as_a_failure
test_sweep_refuses_ambiguous_restored_claude_processes
test_sweep_ignores_a_nested_claude_cli_under_a_conforming_worker
test_sweep_relaunches_top_level_drift_beside_a_nested_conforming_claude
test_sweep_leaves_a_correctly_launched_worker_alone_after_a_config_edit
test_sweep_needs_a_recorded_posture_before_calling_drift
test_remote_sweep_relaunches_drift_and_refuses_ambiguity
test_remote_launch_recovers_permission_drift_and_still_refuses_ambiguity
test_sweep_respawns_authoritatively_missing_pi_secondmate
test_sweep_respawns_authoritatively_missing_pi_signed_secondmate
test_sweep_never_acts_on_ambiguous_existing_process
test_sweep_never_acts_on_transient_unreadability
test_sweep_reports_missing_endpoint_relaunch_failure
test_sweep_never_acts_on_unverified_harness_dead_reading
test_sweep_converges_no_retouch_once_alive
test_sweep_skipped_under_detect_only
test_sweep_noop_with_no_secondmate_meta

echo "# all fm-secondmate-liveness tests passed"
