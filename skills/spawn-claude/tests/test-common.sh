#!/usr/bin/env bash
# Tests for scripts/lib/common.sh — backend-agnostic helpers.
. "$(dirname "$0")/harness.sh"
. "$(dirname "$0")/../scripts/lib/common.sh"

assert_eq "it'\\''s" "$(sc_shell_escape "it's")" "escapes a single quote"
assert_eq "plain" "$(sc_shell_escape "plain")" "leaves plain text alone"

cmd=$(sc_build_claude_cmd "claude" "my-task" "" "" "" "0" "0")
assert_eq "claude --rc --name 'my-task' --dangerously-skip-permissions" "$cmd" "minimal cmux-style command"

cmd=$(sc_build_claude_cmd "'/abs/claude'" "t" "do it" "opus" "" "0" "0")
assert_contains "$cmd" "'/abs/claude' --rc --name 't'" "absolute invocation is passed through verbatim"
assert_contains "$cmd" "--model 'opus'" "model flag"
assert_contains "$cmd" "'do it'" "prompt is appended last"

cmd=$(sc_build_claude_cmd "claude" "t" "" "" "sess-1" "0" "1")
assert_contains "$cmd" "--resume 'sess-1'" "resume flag"
assert_contains "$cmd" "--fork-session" "fork flag"

cmd=$(sc_build_claude_cmd "claude" "t" "" "" "" "1" "0")
assert_contains "$cmd" "--continue" "continue flag"

report
