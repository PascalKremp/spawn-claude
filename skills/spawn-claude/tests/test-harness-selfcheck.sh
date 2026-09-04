. "$(dirname "$0")/harness.sh"
assert_eq "a" "a" "equal strings pass"
assert_contains "hello world" "lo wo" "substring found"

# --- The harness must be able to go RED ---------------------------------
#
# Every assertion in this suite rests on assert_eq/assert_contains, and until
# now only their PASSING branch was ever exercised. A harness whose failure
# path is broken (or whose counters never move) would report a fully green
# suite while being incapable of reporting anything else — the green would
# mean nothing. So: run one deliberately failing assertion of each kind,
# confirm TESTS_FAILED actually moved, then restore the counters so this file
# still reports clean.
#
# The failing assertions' own output goes to /dev/null: they are expected
# failures, and printing "FAIL" lines in a passing run would be its own kind
# of lie. Redirection does not affect the counters — the functions run in this
# shell, only their stdout is discarded.
_saved_run="$TESTS_RUN"
_before_failed="$TESTS_FAILED"

assert_eq "a" "b" "(deliberate failure — not a real result)" >/dev/null
assert_contains "hello" "zzz" "(deliberate failure — not a real result)" >/dev/null

_delta=$((TESTS_FAILED - _before_failed))
_run_delta=$((TESTS_RUN - _saved_run))

TESTS_RUN="$_saved_run"
TESTS_FAILED="$_before_failed"

assert_eq "2" "$_delta" "a failing assert_eq and assert_contains each increment TESTS_FAILED"
assert_eq "2" "$_run_delta" "a failing assertion still increments TESTS_RUN"

# report() must turn a non-zero TESTS_FAILED into a non-zero exit, or a red
# suite would still exit 0 and CI (and run-all.sh) would never notice.
( TESTS_RUN=1; TESTS_FAILED=1; report >/dev/null 2>&1 )
assert_eq "1" "$?" "report exits non-zero when TESTS_FAILED > 0"

report
