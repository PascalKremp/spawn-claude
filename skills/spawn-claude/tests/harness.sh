# Minimal assertion harness. Bash 3.2 compatible (macOS system bash).

# Safety net: every test file sources this harness before touching spawn.sh,
# so any invocation that forgets --dry-run still does nothing live — every
# verb (spawn, read, tell, key, close) honours SPAWN_DRY_RUN, not just spawn.
# A test that genuinely needs a real call must opt out explicitly, e.g.
# `SPAWN_DRY_RUN=0 "$S" spawn ...` for that one call.
export SPAWN_DRY_RUN=1

TESTS_RUN=0
TESTS_FAILED=0

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  ok   %s\n' "$1"; }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  FAIL %s\n' "$1"
  printf '       expected: %s\n' "$2"
  printf '       actual:   %s\n' "$3"
}

assert_eq() {
  if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3" "$1" "$2"; fi
}

assert_contains() {
  case "$1" in
    *"$2"*) _pass "$3" ;;
    *)      _fail "$3" "to contain: $2" "$1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) _fail "$3" "not to contain: $2" "$1" ;;
    *)      _pass "$3" ;;
  esac
}

# assert_exit <expected-code> <label> -- <cmd...>
assert_exit() {
  expected="$1"; label="$2"; shift 3
  "$@" >/dev/null 2>&1
  actual=$?
  if [ "$actual" -eq "$expected" ]; then _pass "$label"
  else _fail "$label" "exit $expected" "exit $actual"; fi
}

report() {
  printf '\n%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ] || exit 1
}
