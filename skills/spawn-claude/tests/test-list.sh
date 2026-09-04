#!/usr/bin/env bash
# Tests for cmd_list — added in the fix round that gave `list` the same
# argument-parsing treatment as every other verb (dry-run, SPAWN_DRY_RUN,
# extra-positional rejection). Before this fix cmd_list ignored its
# arguments entirely: it never read SPAWN_DRY_RUN, never accepted
# --dry-run, and silently swallowed any positional — the one verb that
# broke the "every verb honours the kill switch" guarantee.
. "$(dirname "$0")/harness.sh"
S="$(dirname "$0")/../scripts/spawn.sh"
export SPAWN_REGISTRY="$(mktemp -t spawnreg.XXXXXX)"
rm -f "$SPAWN_REGISTRY"

# Defense in depth, same as test-verbs.sh: this machine may be inside a real
# cmux session. Every dry-run check here must short-circuit before cmux is
# ever touched, so unset the real socket path too.
unset CMUX_SOCKET_PATH

# --- Dry-run with an empty registry: no rows, no reconciliation calls. ---
out=$("$S" list --dry-run 2>&1); rc=$?
assert_eq "0" "$rc" "list --dry-run on an empty registry exits 0"
assert_contains "$out" "cmux workspace list" "list --dry-run names the cmux call it would make"
assert_contains "$out" "nothing registered" "list --dry-run on an empty registry says so"

# --- Dry-run with rows: describe reconciliation honestly. This used to be one
# `cmux workspace list` PER registry row (cmux_ws_exists called it once per
# row); reconciliation now captures the listing ONCE and matches every row
# against it in-process, so the honest description is one call total that
# names the rows it covers. ---
printf '%s\t%s\t%s\t%s\t%s\n' "2026-08-10T00:00:00Z" "refactor-auth" "workspace:94" "window:1" "/tmp/fake-project" > "$SPAWN_REGISTRY"
printf '%s\t%s\t%s\t%s\t%s\n' "2026-08-10T00:00:01Z" "other-task"    "workspace:12" "window:2" "/tmp/other"        >> "$SPAWN_REGISTRY"

out=$("$S" list --dry-run 2>&1); rc=$?
assert_eq "0" "$rc" "list --dry-run with rows exits 0"
assert_contains "$out" "workspace:94" "list --dry-run mentions the first row's ref"
assert_contains "$out" "refactor-auth" "list --dry-run mentions the first row's name"
assert_contains "$out" "workspace:12" "list --dry-run mentions the second row's ref"
assert_contains "$out" "other-task" "list --dry-run mentions the second row's name"
_n=$(printf '%s\n' "$out" | grep -c "cmux workspace list")
assert_eq "1" "$_n" "list --dry-run shows ONE cmux workspace list call for the whole table, not one per row"
assert_contains "$out" "reconciles all 2 registered row(s)" "list --dry-run says how many rows that single call covers"

# --- SPAWN_DRY_RUN=1 alone (no --dry-run flag) must be a real kill switch
# for `list` too, matching every other verb. harness.sh already exports
# SPAWN_DRY_RUN=1, so this call passes no --dry-run flag at all; before the
# fix, cmd_list ignored this env var entirely and would fall through to
# require_cmux (and a live `cmux workspace list` call per row) regardless.
out=$("$S" list 2>&1); rc=$?
assert_eq "0" "$rc" "SPAWN_DRY_RUN=1 alone makes list a dry-run (exit 0, no cmux reachable)"
assert_contains "$out" "cmux workspace list" "SPAWN_DRY_RUN=1 alone makes list describe its cmux call instead of running it"

# --- Extra positional arguments must be rejected, not silently ignored.
# Before the fix, cmd_list took no arguments at all -- `list bogus` and
# `list` behaved identically, since nothing ever inspected "$@".
out=$("$S" list bogus 2>&1); rc=$?
assert_eq "1" "$rc" "list rejects a stray positional"
assert_contains "$out" "too many arguments" "list's rejection names the problem"

out=$("$S" list bogus --dry-run 2>&1); rc=$?
assert_eq "1" "$rc" "list rejects a stray positional even alongside --dry-run"

# --- Ordering: dry-run must resolve nothing and call no cmux -- i.e. the
# dry-run branch must return before require_cmux ever runs, exactly like
# every other verb's resolve-before-require_cmux ordering. Proven here by
# forcing cmux to be entirely unreachable (no CMUX_SOCKET_PATH, no cmux
# binary anywhere) and confirming --dry-run still exits 0 instead of
# require_cmux's exit 2.
out=$(env -u CMUX_SOCKET_PATH -u CMUX_BUNDLED_CLI_PATH -u CMUX_CLAUDE_HOOK_CMUX_BIN \
      SPAWN_REGISTRY="$SPAWN_REGISTRY" "$S" list --dry-run 2>&1); rc=$?
assert_eq "0" "$rc" "list --dry-run never reaches require_cmux, even with cmux fully unreachable"

# --- Fix round: `list` silently dropped LIVE sessions ---------------------
#
# cmux_ws_exists was `cmux_run workspace list | grep -Eq "<ref>"`. `grep -q`
# exits the instant it matches, SIGPIPEing the writer; under spawn.sh's
# `set -o pipefail` the pipeline then returns 141 EVEN ON A SUCCESSFUL MATCH
# once the listing exceeds the 64K pipe buffer. cmd_list's `|| continue` read
# that as "workspace is gone" and dropped the row. The same `|| continue` also
# swallowed any transient cmux error, so `list` printed a bare header and
# exited 0 — indistinguishable from "nothing is running".
#
# SKILL.md promises `list` shows which names are still live, so the failure
# points the WRONG WAY: you conclude an autonomous session is gone while it is
# still running, and stop supervising it.
#
# These tests drive the REAL (non-dry-run) list path, so the same isolation
# rules as test-cmux.sh apply: a fake binary that never talks to cmux, a hard
# executability gate, and a blanked CMUX_BUNDLED_CLI_PATH so cmux_bin() cannot
# fall through to a real CLI. `list` is read-only either way, but the
# isolation must not depend on which verb happens to be under test.

FAKE_CMUX="$(mktemp -t fake-cmux-list.XXXXXX)"
cat > "$FAKE_CMUX" <<'FAKECMUX'
#!/usr/bin/env bash
# NOT the cmux CLI. Serves a synthetic workspace listing only.
case "$1 $2" in
  "workspace list")
    if [ "${FAKE_WS_LIST_EXIT:-0}" != 0 ]; then
      echo "fake cmux: connection refused" >&2; exit "${FAKE_WS_LIST_EXIT}"
    fi
    # The live ref goes FIRST so a `grep -q` reader matches immediately and
    # closes the pipe while ~200K of filler is still unwritten.
    printf '%s\n' "workspace:94  refactor-auth  /tmp/fake-project"
    # `exec`, and LAST, on purpose: the filler writer must BE this process, so
    # that when the reader exits early this script dies of SIGPIPE and reports
    # 141 — exactly what the real cmux CLI does when its output is cut off,
    # and the whole point of the reproduction. A plain `awk ...; exit 0` would
    # absorb the signal and the test would pass against the broken code.
    exec awk 'BEGIN { for (i = 1000; i < 8000; i++) print "workspace:" i "  filler  /tmp/x" }' ;;
  ping) exit 0 ;;
  *) exit 0 ;;
esac
FAKECMUX
chmod +x "$FAKE_CMUX"
[ -x "$FAKE_CMUX" ] || { echo "FATAL: fake cmux not executable — refusing to run live-path tests" >&2; exit 1; }
export CMUX_BUNDLED_CLI_PATH=/nonexistent-cmux

# Registry: workspace:94 is live (present in the listing above), workspace:12
# is not. Reconciliation must keep the first and drop the second.
printf '%s\t%s\t%s\t%s\t%s\n' "2026-08-10T00:00:00Z" "refactor-auth" "workspace:94" "window:1" "/tmp/fake-project" > "$SPAWN_REGISTRY"
printf '%s\t%s\t%s\t%s\t%s\n' "2026-08-10T00:00:01Z" "closed-task"   "workspace:12" "window:2" "/tmp/other"        >> "$SPAWN_REGISTRY"

out=$(env CMUX_SOCKET_PATH=fake-socket CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      SPAWN_REGISTRY="$SPAWN_REGISTRY" SPAWN_DRY_RUN=0 \
      "$S" list 2>&1); rc=$?
assert_eq "0" "$rc" "list exits 0 against a large workspace listing"
assert_contains "$out" "refactor-auth" "list KEEPS a live row even when the listing is larger than the pipe buffer"
assert_contains "$out" "workspace:94" "list shows the live row's ref"
case "$out" in
  *closed-task*) _fail "list drops a row whose workspace is gone" "no closed-task row" "$out" ;;
  *) _pass "list drops a row whose workspace is gone" ;;
esac

# A FAILED `cmux workspace list` is not evidence that anything is gone. It must
# warn and keep every row, never print a bare header and exit 0 — that silent
# empty table is what makes a running session look finished.
out=$(env CMUX_SOCKET_PATH=fake-socket CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      SPAWN_REGISTRY="$SPAWN_REGISTRY" SPAWN_DRY_RUN=0 FAKE_WS_LIST_EXIT=3 \
      "$S" list 2>&1); rc=$?
assert_eq "0" "$rc" "list exits 0 when cmux cannot be reached"
assert_contains "$out" "could not reach cmux" "a failed reconciliation call is reported, not swallowed"
assert_contains "$out" "refactor-auth" "a failed reconciliation call KEEPS rows rather than hiding them"
assert_contains "$out" "closed-task" "a failed reconciliation call keeps every row, since nothing is definite"

# The rc contract cmd_list and the stale-row prune both depend on: 0 present,
# 1 definitely absent, 2 the call failed. Collapsing 2 into 1 is what would
# make a transient cmux error delete live registry rows.
. "$(dirname "$0")/../scripts/lib/cmux.sh"
export CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX"
assert_exit 0 "cmux_ws_exists: present -> 0" -- cmux_ws_exists "workspace:94"
assert_exit 1 "cmux_ws_exists: absent -> 1" -- cmux_ws_exists "workspace:12"
assert_exit 2 "cmux_ws_exists: failed call -> 2, NOT 'absent'" -- env FAKE_WS_LIST_EXIT=3 CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" bash -c '
  set -euo pipefail
  . "$0"
  cmux_ws_exists workspace:94' "$(dirname "$0")/../scripts/lib/cmux.sh"

rm -f "$FAKE_CMUX"
rm -f "$SPAWN_REGISTRY"
report
