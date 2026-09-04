#!/usr/bin/env bash
# SPAWN_DRY_RUN is the kill switch that stands between a careless invocation
# and a live autonomous Claude session. It used to fail OPEN.
#
# Every lifecycle verb tested it with `[ "$dry" -eq 1 ]`. On bash 3.2 a
# non-integer value makes `[` print "integer expression expected" and return
# 2, which an `if` reads as FALSE — so the verb went LIVE. Reproduced against
# the pre-fix code: `SPAWN_DRY_RUN=yes spawn.sh close demo` issued a real
# `cmux workspace close`, and SPAWN_DRY_RUN=2 went live on EVERY verb,
# including `spawn`. Meanwhile cmd_spawn's `[[ ]]` test failed CLOSED under
# `set -u` ("yes: unbound variable"), so the two halves of the CLI disagreed
# about which way a malformed value should break.
#
# The realistic failure is an agent writing SPAWN_DRY_RUN=true *as a safety
# guard* and getting a live close/send/send-key. Fixed by normalising the
# variable once at the top of spawn.sh — anything that is not an explicit 0
# means dry-run — and comparing it as a STRING everywhere after.
#
# ISOLATION. Nothing in this file may reach a real cmux, precisely because it
# probes the live branches:
#   * the fake `cmux` below REFUSES every call, logs it, and exits 1 — it can
#     create, close or message nothing, and it is first in cmux_bin()'s
#     resolution chain so it wins over every real binary on this machine;
#   * CMUX_BUNDLED_CLI_PATH is blanked and CMUX_SOCKET_PATH unset, so the two
#     remaining rungs of that chain cannot reach a live cmux either;
#   * $HOME is faked, so sc_accept_trust writes to a throwaway ~/.claude.json;
#   * SPAWN_REGISTRY points at a temp file.
# The call log then lets each check assert not just the right OUTPUT but that
# NO cmux call was attempted at all.
. "$(dirname "$0")/harness.sh"
S="$(dirname "$0")/../scripts/spawn.sh"

unset CMUX_SOCKET_PATH

FAKE_CMUX="$(mktemp -t refuse-cmux.XXXXXX)"
CMUX_CALL_LOG="$(mktemp -t refuse-cmux-log.XXXXXX)"
cat > "$FAKE_CMUX" <<'FAKECMUX'
#!/usr/bin/env bash
# NOT the cmux CLI. Records what it was asked to do and refuses to do it.
printf '%s\n' "$*" >> "$CMUX_CALL_LOG"
echo "FAKE CMUX (test double): refusing to execute: $*" >&2
exit 1
FAKECMUX
chmod +x "$FAKE_CMUX"
[ -x "$FAKE_CMUX" ] || { echo "FATAL: fake cmux not executable — refusing to run" >&2; exit 1; }

FAKE_HOME="$(mktemp -d -t drh.XXXXXX)"
export CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX"
export CMUX_BUNDLED_CLI_PATH=/nonexistent-cmux
export CMUX_CALL_LOG
export SPAWN_REGISTRY="$(mktemp -t spawnreg.XXXXXX)"
printf '%s\t%s\t%s\t%s\t%s\n' "2026-08-10T00:00:00Z" "demo" "workspace:99" "window:1" "/tmp" > "$SPAWN_REGISTRY"

run_verb() { # run_verb <dry-run-value> <verb-args...>
  _v="$1"; shift
  : > "$CMUX_CALL_LOG"
  env HOME="$FAKE_HOME" SPAWN_DRY_RUN="$_v" SPAWN_NO_VERIFY=1 "$S" "$@" 2>&1
}

# --- Values that MUST be treated as dry-run -----------------------------
#
# "1" is the documented value and the control. "yes"/"true" are what someone
# reaching for a safety guard actually types. "2" is the one that used to slip
# through even the `[[ ]]` test in cmd_spawn, since it is a valid integer that
# simply isn't 1.
for v in 1 yes true 2 on garbage; do

  out=$(run_verb "$v" list); rc=$?
  assert_eq "0" "$rc" "SPAWN_DRY_RUN=$v: list is a dry-run (exit 0)"
  assert_contains "$out" "cmux workspace list" "SPAWN_DRY_RUN=$v: list describes its call instead of making it"

  out=$(run_verb "$v" read demo); rc=$?
  assert_eq "0" "$rc" "SPAWN_DRY_RUN=$v: read is a dry-run (exit 0)"
  assert_contains "$out" "read-screen --workspace workspace:99" "SPAWN_DRY_RUN=$v: read describes its call instead of making it"

  out=$(run_verb "$v" tell demo "hello there"); rc=$?
  assert_eq "0" "$rc" "SPAWN_DRY_RUN=$v: tell is a dry-run (exit 0)"
  assert_contains "$out" "cmux send --workspace workspace:99 -- hello there" "SPAWN_DRY_RUN=$v: tell describes its call instead of making it"

  out=$(run_verb "$v" key demo up); rc=$?
  assert_eq "0" "$rc" "SPAWN_DRY_RUN=$v: key is a dry-run (exit 0)"
  assert_contains "$out" "cmux send-key --workspace workspace:99 up" "SPAWN_DRY_RUN=$v: key describes its call instead of making it"

  out=$(run_verb "$v" wait demo --timeout 5); rc=$?
  assert_eq "0" "$rc" "SPAWN_DRY_RUN=$v: wait is a dry-run (exit 0)"
  assert_contains "$out" "list-status" "SPAWN_DRY_RUN=$v: wait describes its poll instead of polling"

  out=$(run_verb "$v" close demo); rc=$?
  assert_eq "0" "$rc" "SPAWN_DRY_RUN=$v: close is a dry-run (exit 0)"
  assert_contains "$out" "cmux workspace close workspace:99" "SPAWN_DRY_RUN=$v: close describes its call instead of making it"

  # `spawn` too — the verb whose live branch actually starts an autonomous
  # session. --terminal cmux forces the cmux backend so this exercises the
  # same branch a real spawn would take.
  out=$(run_verb "$v" spawn --terminal cmux "dr-test" "seed prompt" /tmp); rc=$?
  assert_eq "0" "$rc" "SPAWN_DRY_RUN=$v: spawn is a dry-run (exit 0)"
  assert_contains "$out" "workspace create" "SPAWN_DRY_RUN=$v: spawn describes its create call instead of making it"

  # The decisive check: across all seven verbs above, the fake cmux was never
  # invoked even once. Output assertions alone would not catch a verb that
  # printed its dry-run line AND then went on to call cmux.
  assert_eq "" "$(cat "$CMUX_CALL_LOG")" "SPAWN_DRY_RUN=$v: no cmux call was attempted by any verb"

  # A dry-run must not mutate global state either — sc_accept_trust is skipped.
  if [ -e "$FAKE_HOME/.claude.json" ]; then
    _fail "SPAWN_DRY_RUN=$v: spawn dry-run never writes ~/.claude.json" "no .claude.json" "file was created"
    rm -f "$FAKE_HOME/.claude.json"
  else
    _pass "SPAWN_DRY_RUN=$v: spawn dry-run never writes ~/.claude.json"
  fi
done

# --- Values that must NOT be treated as dry-run -------------------------
#
# Only an explicit 0 goes live, plus empty — which keeps the long-standing
# "${SPAWN_DRY_RUN:-0}" meaning of an unset/blank variable, so normalising
# does not quietly change what an unset switch means.
#
# Proven WITHOUT any live effect: CMUX_SOCKET_PATH is unset, so a lifecycle
# verb that takes the live branch hits require_cmux and exits 2 before any
# cmux call. Reaching that specific error IS the proof it went live.
for v in 0 ""; do
  _label="${v:-<empty>}"

  out=$(run_verb "$v" close demo); rc=$?
  assert_eq "2" "$rc" "SPAWN_DRY_RUN=$_label: close takes the live branch (require_cmux exits 2)"
  assert_contains "$out" "requires a cmux session" "SPAWN_DRY_RUN=$_label: close reaches require_cmux, i.e. it is NOT a dry-run"

  out=$(run_verb "$v" list); rc=$?
  assert_eq "2" "$rc" "SPAWN_DRY_RUN=$_label: list takes the live branch (require_cmux exits 2)"
done

# `spawn --terminal cmux` skips cmux_available, so its live branch reaches the
# fake binary — which refuses, logs the attempt, and exits 1. That refusal is
# the strongest available evidence the switch really does gate the launch
# path: with the switch off, `workspace create` is genuinely attempted.
: > "$CMUX_CALL_LOG"
out=$(run_verb 0 spawn --terminal cmux "live-branch-test" "seed" /tmp); rc=$?
assert_eq "1" "$rc" "SPAWN_DRY_RUN=0: spawn takes the live branch and fails on the refusing fake cmux"
assert_contains "$(cat "$CMUX_CALL_LOG")" "workspace create" "SPAWN_DRY_RUN=0: spawn actually attempts 'workspace create' (proving the switch gates it)"
assert_contains "$out" "FAKE CMUX" "SPAWN_DRY_RUN=0: the attempt hit the test double, never a real cmux"

rm -rf "$FAKE_CMUX" "$CMUX_CALL_LOG" "$FAKE_HOME" "$SPAWN_REGISTRY"
report
