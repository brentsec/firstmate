#!/usr/bin/env bash
# Real end-to-end regression for Claude permission posture across Herdr native
# session restoration.
#
# This test uses the public fm-spawn, fm-crew-state, and fm-control interfaces
# inside a generated non-default Herdr lab.
# It proves:
#   1. Initial Claude spawn carries --dangerously-skip-permissions and visibly
#      reaches bypass mode.
#   2. Herdr native restore synthesizes claude --resume without that flag and
#      the public state reader reports permission drift instead of alive.
#   3. Adding only the missing flag to that exact resume command restores bypass
#      mode, separating the causal flag loss from Claude session persistence.
#   4. Public relaunch stops the attributed restored process, reuses the exact
#      endpoint and isolated worktree, and visibly returns in bypass mode with
#      no human input.
#
# Opt in with FM_CLAUDE_PERMISSION_RESTORE_E2E=1.
# The lab helper owns every Herdr lifecycle action and every task-specific Herdr
# command, including the required non-default named-session safety tripwire.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
fm_live_gate opt-in FM_CLAUDE_PERMISSION_RESTORE_E2E claude herdr treehouse jq git

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || {
  echo "not ok - Herdr lab helper is unavailable: $HERDR_LAB_HELPER" >&2
  exit 1
}
CLAUDE_CREDENTIALS=${CLAUDE_CREDENTIALS:-$HOME/.claude/.credentials.json}
[ -f "$CLAUDE_CREDENTIALS" ] || {
  echo "skip: an existing Claude credential file is required for the real permission-restore E2E"
  exit 0
}

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name claude-permission-restore-e2e)
SCRATCH=
# Every exit path runs under `set -euo pipefail`, so a failed assertion leaves
# through this trap: it owns the lab teardown AND the disposable scratch tree,
# whose generated worktrees and credential symlink must never accumulate across
# failing runs. Preserving them for a post-mortem stays a deliberate choice.
cleanup() {
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"
  if [ -n "$SCRATCH" ] && [ "${FM_CLAUDE_PERMISSION_RESTORE_E2E_KEEP_SCRATCH:-0}" != 1 ]; then
    rm -rf "$SCRATCH"
  fi
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-permission-restore.XXXXXX")
PROJECT="$SCRATCH/project"
HOME_DIR="$SCRATCH/home"
CLAUDE_DIR="$SCRATCH/claude"
mkdir -p "$PROJECT" "$HOME_DIR/state" "$HOME_DIR/data/e2e-claude" "$HOME_DIR/config" "$CLAUDE_DIR"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
printf 'herdr\n' > "$HOME_DIR/config/backend"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
ln -s "$CLAUDE_CREDENTIALS" "$CLAUDE_DIR/.credentials.json"
printf '{"hasCompletedOnboarding":true,"projects":{}}\n' > "$CLAUDE_DIR/.claude.json"

cat > "$HOME_DIR/data/e2e-claude/brief.md" <<'EOF'
# Task

Delivery contract: mode=direct-PR

## Captain's intent

This is a disposable end-to-end launch diagnostic.
Reply exactly E2E_READY, do not run tools or modify files, and then wait.

## Firstmate spec

Do not change the project.
Do not merge, perform destructive or security-sensitive actions, or make decisions for anyone.
EOF

printf '# disposable claude permission restore diagnostic\n' > "$PROJECT/README.md"
printf '# Disposable diagnostic\n\nFollow the launch instructions exactly.\n' > "$PROJECT/CLAUDE.md"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.name 'Firstmate E2E'
git -C "$PROJECT" config user.email 'e2e@example.invalid'
(cd "$PROJECT" && treehouse init >/dev/null)
printf 'max_trees = 2\nroot = "./"\n' > "$PROJECT/treehouse.toml"
git -C "$PROJECT" add README.md CLAUDE.md treehouse.toml
git -C "$PROJECT" commit -qm initial

CLAUDE_CONFIG_DIR="$CLAUDE_DIR" \
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" integration install claude >/dev/null
tmp_settings="$CLAUDE_DIR/settings.json.tmp"
jq '. + {skipDangerousModePermissionPrompt:true}' "$CLAUDE_DIR/settings.json" > "$tmp_settings"
mv "$tmp_settings" "$CLAUDE_DIR/settings.json"

PARENT_JSON=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" \
  workspace create --cwd "$PROJECT" --label 'fm-e2e-parent' --no-focus)
PARENT_PANE=$(printf '%s' "$PARENT_JSON" | jq -er '.result.root_pane.pane_id')

cat > "$SCRATCH/spawn.sh" <<EOF
#!/usr/bin/env bash
set +e
env FM_HOME=$(printf %q "$HOME_DIR") FM_ROOT_OVERRIDE=$(printf %q "$ROOT") \\
  FM_BACKEND=herdr FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 \\
  CLAUDE_CONFIG_DIR=$(printf %q "$CLAUDE_DIR") \\
  $(printf %q "$ROOT/bin/fm-spawn.sh") e2e-claude $(printf %q "$PROJECT") \\
  --mode direct-PR --yolo off --harness claude > $(printf %q "$SCRATCH/spawn.out") 2>&1
printf '%s\n' "\$?" > $(printf %q "$SCRATCH/spawn.rc")
EOF
chmod +x "$SCRATCH/spawn.sh"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PARENT_PANE" \
  "bash $(printf %q "$SCRATCH/spawn.sh")" >/dev/null

for _ in $(seq 1 360); do
  [ -s "$SCRATCH/spawn.rc" ] && break
  sleep 0.5
done
[ -s "$SCRATCH/spawn.rc" ] || { echo "not ok - Claude spawn did not finish" >&2; exit 1; }
[ "$(cat "$SCRATCH/spawn.rc")" = 0 ] || {
  echo "not ok - Claude spawn failed: $(tr '\n' ' ' < "$SCRATCH/spawn.out")" >&2
  exit 1
}
META="$HOME_DIR/state/e2e-claude.meta"
TASK_PANE=$(sed -n 's/^herdr_pane_id=//p' "$META" | tail -1)
TASK_WT=$(sed -n 's/^worktree=//p' "$META" | tail -1)
[ -n "$TASK_PANE" ] && [ -n "$TASK_WT" ] && [ -d "$TASK_WT" ] || {
  echo "not ok - spawned task metadata did not identify its pane and worktree" >&2
  exit 1
}

pane_process_flags() {
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane process-info --pane "$TASK_PANE" \
    | jq -c '
      def has_auto:
        (.argv // []) as $a
        | any(range(0; ($a | length));
            $a[.] == "--permission-mode=auto"
            or ($a[.] == "--permission-mode" and $a[. + 1] == "auto"));
      [.result.process_info.foreground_processes[]?] as $p
      | {
          has_bypass: any($p[]; any(.argv[]?; . == "--dangerously-skip-permissions")),
          has_auto: any($p[]; has_auto),
          has_resume: any($p[]; any(.argv[]?; . == "--resume")),
          has_claude: any($p[];
            (((.name // "") | split("/") | last) | contains("claude"))
            or ((((.argv // [""])[0]) | split("/") | last) | contains("claude")))
        }'
}

# Claude paints its permission-mode status line only after its process is
# already visible in argv, so every screen assertion has to poll rather than
# read once; a single read races the paint and fails a conforming worker.
assert_screen() {  # <needle>
  local needle=$1 screen=''
  for _ in $(seq 1 60); do
    screen=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" \
      pane read "$TASK_PANE" --source detection --lines 120 2>/dev/null || true)
    printf '%s\n' "$screen" | grep -Fi "$needle" >/dev/null && return 0
    sleep 0.5
  done
  printf 'not ok - the pane never showed "%s"; last screen:\n%s\n' "$needle" "$screen" >&2
  return 1
}

INITIAL_FLAGS=''
for _ in $(seq 1 120); do
  INITIAL_FLAGS=$(pane_process_flags 2>/dev/null || true)
  printf '%s' "$INITIAL_FLAGS" | jq -e \
    '.has_claude == true and .has_bypass == true and .has_resume == false' >/dev/null 2>&1 && break
  sleep 0.5
done
printf '%s' "$INITIAL_FLAGS" | jq -e \
  '.has_claude == true and .has_bypass == true and .has_resume == false' >/dev/null
assert_screen 'bypass permissions on'
printf 'ok - initial Firstmate Claude spawn is visibly in bypass mode\n'

"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null
sleep 1
CLAUDE_CONFIG_DIR="$CLAUDE_DIR" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null
RESTORED_FLAGS=''
for _ in $(seq 1 180); do
  RESTORED_FLAGS=$(pane_process_flags 2>/dev/null || true)
  printf '%s' "$RESTORED_FLAGS" | jq -e \
    '.has_claude == true and .has_resume == true and .has_bypass == false and .has_auto == false' >/dev/null 2>&1 && break
  sleep 0.5
done
printf '%s' "$RESTORED_FLAGS" | jq -e \
  '.has_claude == true and .has_resume == true and .has_bypass == false and .has_auto == false' >/dev/null
assert_screen 'manual mode'
printf 'ok - Herdr native restore reproduced claude --resume in visible manual mode\n'

RESTORED_INFO=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" \
  pane process-info --pane "$TASK_PANE")
RESUME_ID=$(printf '%s' "$RESTORED_INFO" | jq -er '
  [.result.process_info.foreground_processes[]?
   | select(any(.argv[]?; . == "--resume"))
   | .argv as $a | ($a | index("--resume")) as $i | $a[$i + 1]][0]')
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$TASK_PANE" '/exit' >/dev/null
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$TASK_PANE" Enter >/dev/null
AFTER_EXIT=''
for _ in $(seq 1 120); do
  AFTER_EXIT=$(pane_process_flags 2>/dev/null || true)
  printf '%s' "$AFTER_EXIT" | jq -e '.has_claude == false' >/dev/null 2>&1 && break
  sleep 0.5
done
printf '%s' "$AFTER_EXIT" | jq -e '.has_claude == false' >/dev/null
COUNTER_CMD="CLAUDE_CONFIG_DIR=$(printf %q "$CLAUDE_DIR") CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --resume $(printf %q "$RESUME_ID") --dangerously-skip-permissions"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$TASK_PANE" "$COUNTER_CMD" >/dev/null
DIRECT_COUNTER_FLAGS=''
for _ in $(seq 1 120); do
  DIRECT_COUNTER_FLAGS=$(pane_process_flags 2>/dev/null || true)
  printf '%s' "$DIRECT_COUNTER_FLAGS" | jq -e \
    '.has_claude == true and .has_resume == true and .has_bypass == true' >/dev/null 2>&1 && break
  sleep 0.5
done
printf '%s' "$DIRECT_COUNTER_FLAGS" | jq -e \
  '.has_claude == true and .has_resume == true and .has_bypass == true' >/dev/null
assert_screen 'bypass permissions on'
printf 'ok - adding only bypass to the same claude --resume restores visible bypass mode\n'

"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null
sleep 1
CLAUDE_CONFIG_DIR="$CLAUDE_DIR" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null
for _ in $(seq 1 180); do
  RESTORED_FLAGS=$(pane_process_flags 2>/dev/null || true)
  printf '%s' "$RESTORED_FLAGS" | jq -e \
    '.has_claude == true and .has_resume == true and .has_bypass == false' >/dev/null 2>&1 && break
  sleep 0.5
done
printf '%s' "$RESTORED_FLAGS" | jq -e \
  '.has_claude == true and .has_resume == true and .has_bypass == false' >/dev/null
STATE_OUT=$(env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" CLAUDE_CONFIG_DIR="$CLAUDE_DIR" \
  "$ROOT/bin/fm-crew-state.sh" e2e-claude)
printf '%s\n' "$STATE_OUT" | grep -F \
  'lacks the selected unattended permission flag; relaunch in place' >/dev/null
printf 'ok - public state reader detects the restored permission drift\n'

cat > "$SCRATCH/relaunch.sh" <<EOF
#!/usr/bin/env bash
set +e
env FM_HOME=$(printf %q "$HOME_DIR") FM_ROOT_OVERRIDE=$(printf %q "$ROOT") \\
  FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 \\
  CLAUDE_CONFIG_DIR=$(printf %q "$CLAUDE_DIR") \\
  FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=15 FM_CONTROL_LAUNCH_WAIT=30 \\
  $(printf %q "$ROOT/bin/fm-control.sh") e2e-claude relaunch \\
  --note 'Replace the runtime-restored Claude process and continue the disposable diagnostic.' \\
  > $(printf %q "$SCRATCH/relaunch.out") 2>&1
printf '%s\n' "\$?" > $(printf %q "$SCRATCH/relaunch.rc")
EOF
chmod +x "$SCRATCH/relaunch.sh"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PARENT_PANE" \
  "bash $(printf %q "$SCRATCH/relaunch.sh")" >/dev/null
for _ in $(seq 1 360); do
  [ -s "$SCRATCH/relaunch.rc" ] && break
  sleep 0.5
done
[ -s "$SCRATCH/relaunch.rc" ] || { echo "not ok - Claude recovery did not finish" >&2; exit 1; }
[ "$(cat "$SCRATCH/relaunch.rc")" = 0 ] || {
  echo "not ok - Claude recovery failed: $(tr '\n' ' ' < "$SCRATCH/relaunch.out")" >&2
  exit 1
}
RECOVERED_FLAGS=''
for _ in $(seq 1 120); do
  RECOVERED_FLAGS=$(pane_process_flags 2>/dev/null || true)
  printf '%s' "$RECOVERED_FLAGS" | jq -e \
    '.has_claude == true and .has_bypass == true and .has_resume == false' >/dev/null 2>&1 && break
  sleep 0.5
done
printf '%s' "$RECOVERED_FLAGS" | jq -e \
  '.has_claude == true and .has_bypass == true and .has_resume == false' >/dev/null
assert_screen 'bypass permissions on'
[ "$(sed -n 's/^herdr_pane_id=//p' "$META" | tail -1)" = "$TASK_PANE" ]
[ "$(sed -n 's/^worktree=//p' "$META" | tail -1)" = "$TASK_WT" ]
[ -d "$TASK_WT" ]
printf 'ok - public recovery preserves the endpoint and isolated copy and restores visible bypass mode\n'

"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"
trap - EXIT
rm -rf "$SCRATCH"
printf '# all real Claude permission-restore E2E assertions passed\n'
