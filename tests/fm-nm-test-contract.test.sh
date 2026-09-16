#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty,
# and must steer the Test step toward diff-focused local validation instead.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_test_instructions_steer_diff_focused_validation() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local instructions
  instructions=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
test_cfg = doc["test"] || {}
val = test_cfg.is_a?(Hash) ? test_cfg["instructions"] : nil
puts val.is_a?(String) ? val : ""
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  [ -n "$instructions" ] \
    || fail "test.instructions must be set so the Test step stays diff-focused locally"
  case "$instructions" in
    *fm-test-run.sh*changed*) : ;;
    *) fail "test.instructions must point the Test step at the changed-file-scoped selector (bin/fm-test-run.sh --changed); got: $instructions" ;;
  esac
  case "$instructions" in
    *"entire tests/ suite"*|*"complete deterministic regression"*) : ;;
    *) fail "test.instructions must tell the Test step not to walk the full suite locally; got: $instructions" ;;
  esac
  pass "no-mistakes test.instructions steers the Test step to diff-focused local validation"
}

test_nm_has_no_deterministic_test_command
test_nm_test_instructions_steer_diff_focused_validation
