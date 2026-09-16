#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty,
# and must carry a trusted test.instructions policy for the Test step instead.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

if ! command -v ruby >/dev/null 2>&1; then
  echo "skip: ruby not installed; cannot parse .no-mistakes.yaml for these contracts"
  exit 0
fi

test_nm_has_no_deterministic_test_command() {
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
  local instructions
  instructions=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
test_cfg = doc["test"] || {}
val = test_cfg.is_a?(Hash) ? test_cfg["instructions"] : nil
puts val.is_a?(String) ? val : ""
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  [ -n "$instructions" ] \
    || fail "test.instructions must be a non-empty string so the Test step stays diff-focused locally"
  pass "no-mistakes sets a non-empty test.instructions policy for the Test step"
}

test_nm_has_no_deterministic_test_command
test_nm_test_instructions_steer_diff_focused_validation
