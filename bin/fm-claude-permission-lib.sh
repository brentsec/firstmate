#!/usr/bin/env bash
# fm-claude-permission-lib.sh - the single owner of Firstmate's Claude worker
# permission-mode selection and exact invocation conformance test.
#
# config/claude-permission-mode selects exactly one unattended worker posture:
# absent or `bypass` means `--dangerously-skip-permissions`, while `auto` means
# `--permission-mode auto`.
# fm_claude_permission_mode reads that choice without mutation, and
# fm_claude_permission_flag renders the launch flag every spawn and relaunch
# must carry.
#
# A terminal provider may restore a Claude session itself instead of replaying
# Firstmate's launch command.
# fm_claude_argv_permission_state checks one exact argv array from that running
# process as conforming|drifted|ambiguous|unreadable.
# Flattened command text is deliberately not accepted because a worker prompt
# may itself mention either permission flag and create false evidence.
#
# This posture grants command autonomy only inside the worker.
# It does not grant merge authority or permission for destructive,
# irreversible, security-sensitive, or ask-user decisions, which remain owned
# by Firstmate's separate task-lifecycle contracts.
#
# Source only.

_FM_CLAUDE_PERMISSION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-config-inherit-lib.sh disable=SC1091
. "$_FM_CLAUDE_PERMISSION_LIB_DIR/fm-config-inherit-lib.sh"

fm_claude_permission_mode() {  # <config-dir> -> bypass|auto
  local config_dir=${1:-} file present mode
  [ -n "$config_dir" ] || {
    echo "error: Claude permission mode needs a config directory" >&2
    return 1
  }
  file="$config_dir/claude-permission-mode"
  present=$(fm_config_source_present "$file") || return 1
  if [ "$present" = 0 ]; then
    printf 'bypass'
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/claude-permission-mode must be a readable regular file holding one of: bypass, auto" >&2
    return 1
  fi
  mode=$(tr -d '[:space:]' < "$file" || true)
  case "$mode" in
    bypass|auto) printf '%s' "$mode" ;;
    *)
      echo "error: config/claude-permission-mode holds '$mode'; accepted values are: bypass (--dangerously-skip-permissions, the default when the file is absent), auto (--permission-mode auto)" >&2
      return 1
      ;;
  esac
}

fm_claude_permission_flag() {  # <bypass|auto>
  case "${1:-}" in
    bypass) printf '%s' '--dangerously-skip-permissions' ;;
    auto) printf '%s' '--permission-mode auto' ;;
    *) return 1 ;;
  esac
}

# Match only process identity fields, never arbitrary command arguments.
# Claude's packaged executable may expose either a claude-named kernel process
# or a claude-named argv[0] path, so either exact identity surface is enough.
#
# The name must BE the executable's own name, never merely contain `claude`,
# because this attribution is what licenses stopping and replacing a live
# worker: a claude-NAMED script a healthy worker runs in its own pane
# (bin/fm-claude-trust.sh, tests/fm-claude-*.test.sh - a shebang exec puts that
# path in argv[0]) must never be attributed as the Claude process itself.
# Anchoring at the start excludes every `fm-claude-*` tool in this repo, and
# the script suffixes excluded below cover a claude-prefixed wrapper script.
# Claude's own identity is the bare launcher name (verified shape on Herdr:
# kernel name `node` with argv[0] `claude`, the same shape Pi presents -
# docs/verification/runtime-backends.md "Stale agent registration"). A name
# this rejects attributes no process at all, which is `unobserved` - the
# fail-safe direction, never drift.
fm_claude_process_matches() {  # <name> <argv0>
  local name=${1:-} argv0=${2:-} base
  for base in "$name" "$argv0"; do
    base=${base##*/}
    base=${base#-}
    case "$base" in
      *.sh|*.bash|*.zsh|*.py|*.rb|*.pl) continue ;;
      claude|claude-*) return 0 ;;
    esac
  done
  return 1
}

fm_claude_argv_permission_state() {  # <bypass|auto> <argv-json>
  local mode=${1:-} argv=${2:-}
  case "$mode" in bypass|auto) ;; *) printf 'unreadable'; return 0 ;; esac
  command -v jq >/dev/null 2>&1 || { printf 'unreadable'; return 0; }
  printf '%s' "$argv" | jq -r --arg mode "$mode" '
    if type != "array" or any(.[]; type != "string") then
      "unreadable"
    else
      ([.[] | select(. == "--dangerously-skip-permissions")] | length > 0) as $bypass
      | ([range(0; length) as $i
          | select(.[ $i ] == "--permission-mode=auto"
                   or (.[ $i ] == "--permission-mode" and .[$i + 1] == "auto"))]
         | length > 0) as $auto
      | if $bypass and $auto then "ambiguous"
        elif $mode == "bypass" and $bypass then "conforming"
        elif $mode == "auto" and $auto then "conforming"
        else "drifted"
        end
    end
  ' 2>/dev/null || printf 'unreadable'
}
