#!/usr/bin/env bash
# Reused task names used to break every lifecycle verb, permanently.
#
# The registry is append-only, `close` never removes its row, and reg_resolve
# never filtered by liveness. So the SECOND spawn under a given name made
# read/tell/key/wait/close <name> fail with "Ambiguous target", naming stale,
# long-closed workspaces as candidates. skills/brainc/scripts/brainc.sh spawns
# with the hardcoded name "brainc", so from the second brainc onward the
# headline feature was unusable by name for its primary dependent.
#
# Ruling: prune on append. cmd_spawn drops this name's rows whose workspace no
# longer exists, just before recording the new one — and ONLY on a definite
# "absent" (cmux_ws_exists rc 1), never on "call failed" (rc 2). Two genuinely
# live sessions sharing a name must still collide; that ambiguous-target error
# is the correct outcome, not something to paper over.
#
# ISOLATION: same rules as test-cmux.sh — a fake cmux binary that never talks
# to a real one, a hard executability gate, a blanked CMUX_BUNDLED_CLI_PATH,
# a fake $HOME, and SPAWN_REGISTRY on a temp file.
. "$(dirname "$0")/harness.sh"
. "$(dirname "$0")/../scripts/lib/registry.sh"
S="$(dirname "$0")/../scripts/spawn.sh"

unset CMUX_SOCKET_PATH

export SPAWN_REGISTRY="$(mktemp -t spawnreg.XXXXXX)"

# --- reg_drop, on its own ------------------------------------------------
rm -f "$SPAWN_REGISTRY"
reg_append "brainc"  "workspace:10" "window:1" "/Users/x/vault"
reg_append "other"   "workspace:11" "window:1" "/Users/x/proj"
reg_append "brainc"  "workspace:12" "window:1" "/Users/x/vault"

reg_drop "brainc" "workspace:10"
assert_eq "2" "$(reg_list | wc -l | tr -d ' ')" "reg_drop removes exactly the named row"
assert_eq "workspace:12" "$(reg_resolve brainc)" "reg_drop leaves the surviving row resolvable"
assert_contains "$(reg_list)" "workspace:11" "reg_drop leaves other names untouched"

# The name/ref PAIR must match — a ref alone must not delete another task's row.
reg_drop "brainc" "workspace:11"
assert_contains "$(reg_list)" "workspace:11" "reg_drop will not delete a row belonging to a different name"

# Nothing to drop is success, not an error, and must not disturb the file.
_before=$(reg_list)
reg_drop "brainc" "workspace:999"; rc=$?
assert_eq "0" "$rc" "reg_drop exits 0 when there is nothing to drop"
assert_eq "$_before" "$(reg_list)" "reg_drop leaves the registry byte-identical when nothing matches"

# A cwd containing spaces (the last TSV field) must survive a rewrite the row
# is only passing through.
rm -f "$SPAWN_REGISTRY"
reg_append "spacey" "workspace:20" "window:1" "/Users/x/my proj"
reg_append "spacey" "workspace:21" "window:1" "/Users/x/my proj"
reg_drop "spacey" "workspace:20"
assert_eq "/Users/x/my proj" "$(reg_list | awk -F'\t' '{print $5}')" "reg_drop preserves a cwd with spaces verbatim"

# --- prune-on-spawn, end to end ------------------------------------------

FAKE_CMUX="$(mktemp -t fake-cmux-prune.XXXXXX)"
cat > "$FAKE_CMUX" <<'FAKECMUX'
#!/usr/bin/env bash
# NOT the cmux CLI. Creates nothing; serves a synthetic listing.
case "$1 $2" in
  "workspace create")
    printf '%s\n' "OK ${FAKE_NEW_REF:-workspace:99}"; exit 0 ;;
  "workspace list")
    if [ "${FAKE_WS_LIST_EXIT:-0}" != 0 ]; then
      echo "fake cmux: connection refused" >&2; exit "${FAKE_WS_LIST_EXIT}"
    fi
    printf '%s\n' "${FAKE_WS_LIST:-}"; exit 0 ;;
  ping) exit 0 ;;
  *) exit 0 ;;
esac
FAKECMUX
chmod +x "$FAKE_CMUX"
[ -x "$FAKE_CMUX" ] || { echo "FATAL: fake cmux not executable — refusing to run live-path tests" >&2; exit 1; }
export CMUX_BUNDLED_CLI_PATH=/nonexistent-cmux
FAKE_HOME="$(mktemp -d -t prunehome.XXXXXX)"

spawn_brainc() { # spawn_brainc <new-ref> <ws-list> [ws-list-exit]
  env HOME="$FAKE_HOME" CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      CMUX_BUNDLED_CLI_PATH=/nonexistent-cmux \
      SPAWN_REGISTRY="$SPAWN_REGISTRY" SPAWN_DRY_RUN=0 SPAWN_NO_VERIFY=1 \
      FAKE_NEW_REF="$1" FAKE_WS_LIST="$2" FAKE_WS_LIST_EXIT="${3:-0}" \
      "$S" spawn --terminal cmux "brainc" "p" /tmp 2>&1
}

# The brainc case. workspace:10 is a closed session's leftover row; the new
# spawn takes workspace:30. Only workspace:30 exists in cmux, so the stale row
# must go and `brainc` must resolve cleanly instead of reporting ambiguity.
rm -f "$SPAWN_REGISTRY"
reg_append "brainc" "workspace:10" "window:1" "/Users/x/vault"
out=$(spawn_brainc "workspace:30" "workspace:30  brainc  /Users/x/vault"); rc=$?
assert_eq "0" "$rc" "second spawn under a reused name exits 0"
assert_eq "1" "$(reg_list | wc -l | tr -d ' ')" "the stale same-name row is pruned on append"
assert_eq "workspace:30" "$(reg_resolve brainc)" "a reused name resolves to the live session instead of failing as ambiguous"

# Regression guard for the actual user-visible symptom: `close brainc` must
# reach a real target rather than dying on "Ambiguous target".
out=$(env SPAWN_REGISTRY="$SPAWN_REGISTRY" SPAWN_DRY_RUN=1 "$S" close brainc 2>&1); rc=$?
assert_eq "0" "$rc" "close <reused-name> works after the prune"
assert_contains "$out" "cmux workspace close workspace:30" "close targets the live session, not a stale candidate"

# A LIVE same-name row must NOT be pruned. Two genuinely live sessions sharing
# a name still collide — and that ambiguous-target error is correct, because
# silently picking one of them would steer the wrong autonomous session.
rm -f "$SPAWN_REGISTRY"
reg_append "brainc" "workspace:10" "window:1" "/Users/x/vault"
out=$(spawn_brainc "workspace:30" "$(printf 'workspace:10  brainc  /Users/x/vault\nworkspace:30  brainc  /Users/x/vault')")
assert_eq "2" "$(reg_list | wc -l | tr -d ' ')" "a LIVE same-name row is kept, not pruned"
assert_exit 3 "two live sessions sharing a name still report an ambiguous target" -- reg_resolve brainc

# A FAILED `cmux workspace list` is not evidence that anything is gone. Nothing
# may be pruned on rc 2 — deleting a row here would throw away the only handle
# on a running autonomous session.
rm -f "$SPAWN_REGISTRY"
reg_append "brainc" "workspace:10" "window:1" "/Users/x/vault"
out=$(spawn_brainc "workspace:30" "" 3)
assert_eq "2" "$(reg_list | wc -l | tr -d ' ')" "an unreachable cmux prunes NOTHING (rc 2 is not 'absent')"
assert_contains "$(reg_list)" "workspace:10" "the pre-existing row survives a failed reconciliation call"

# Spawn also prunes OTHER names' rows whose workspace is definitely gone: a
# registry row for a closed workspace is a lie that cmux can make dangerous by
# reusing the ref (see the workspace:72 case below).
rm -f "$SPAWN_REGISTRY"
reg_append "brainc"      "workspace:10" "window:1" "/Users/x/vault"
reg_append "other-task"  "workspace:11" "window:1" "/Users/x/proj"
reg_append "live-task"   "workspace:12" "window:1" "/Users/x/live"
out=$(spawn_brainc "workspace:30" "$(printf 'workspace:12  live-task\nworkspace:30  brainc')")
assert_not_contains "$(reg_list)" "other-task" "a different name's dead row is pruned on spawn"
assert_contains "$(reg_list)" "live-task" "a different name's LIVE row is kept"

# The workspace:72 bug: cmux reused a closed workspace's ref for a new spawn,
# leaving two rows with the same ref. The new spawn must evict the old row
# even though the ref is "live" (it now belongs to the new session).
rm -f "$SPAWN_REGISTRY"
reg_append "triage-oldest-100" "workspace:72" "window:1" "/Users/x/old"
out=$(spawn_brainc "workspace:72" "workspace:72  brainc")
assert_eq "1" "$(reg_list | wc -l | tr -d ' ')" "a reused ref leaves exactly one row"
assert_eq "workspace:72" "$(reg_resolve brainc)" "the surviving row is the new spawn"
assert_not_contains "$(reg_list)" "triage-oldest-100" "the stale row sharing the ref is removed on register"

# Title mismatch: the ref exists in cmux but belongs to a differently named
# workspace, so the row is stale. Pruned by spawn ...
rm -f "$SPAWN_REGISTRY"
reg_append "triage-oldest-100" "workspace:72" "window:1" "/Users/x/old"
reg_append "keeper" "workspace:40" "window:1" "/Users/x/k"
out=$(spawn_brainc "workspace:30" "$(printf 'workspace:72  dns-tischlein-pro\n* workspace:40  keeper  [selected]\nworkspace:30  brainc')")
assert_not_contains "$(reg_list)" "triage-oldest-100" "spawn prunes a row whose ref now belongs to a differently named workspace"
assert_contains "$(reg_list)" "keeper" "a row whose live title matches (with decorations) is kept"

# ... and by list, which rewrites the registry rather than merely hiding rows.
rm -f "$SPAWN_REGISTRY"
reg_append "triage-oldest-100" "workspace:72" "window:1" "/Users/x/old"
reg_append "dns-tischlein-pro" "workspace:72" "window:1" "/Users/x/dns"
out=$(env HOME="$FAKE_HOME" CMUX_SOCKET_PATH=fake CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      CMUX_BUNDLED_CLI_PATH=/nonexistent-cmux SPAWN_REGISTRY="$SPAWN_REGISTRY" SPAWN_DRY_RUN=0 \
      FAKE_WS_LIST="workspace:72  dns-tischlein-pro" "$S" list 2>&1)
assert_not_contains "$out" "triage-oldest-100" "list does not show a name-mismatched duplicate-ref row"
assert_contains "$out" "dns-tischlein-pro" "list shows the row matching the live title"
assert_not_contains "$(reg_list)" "triage-oldest-100" "list prunes the stale row from the registry file"

# A failed list call prunes nothing.
rm -f "$SPAWN_REGISTRY"
reg_append "triage-oldest-100" "workspace:72" "window:1" "/Users/x/old"
out=$(env HOME="$FAKE_HOME" CMUX_SOCKET_PATH=fake CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      CMUX_BUNDLED_CLI_PATH=/nonexistent-cmux SPAWN_REGISTRY="$SPAWN_REGISTRY" SPAWN_DRY_RUN=0 \
      FAKE_WS_LIST_EXIT=3 "$S" list 2>&1)
assert_contains "$(reg_list)" "triage-oldest-100" "list on an unreachable cmux leaves the registry untouched"

# reg_drop_ref removes every row with the ref, whatever the name.
rm -f "$SPAWN_REGISTRY"
reg_append "a" "workspace:5" "window:1" "/x"
reg_append "b" "workspace:5" "window:1" "/x"
reg_append "c" "workspace:6" "window:1" "/x"
reg_drop_ref "workspace:5"
assert_eq "1" "$(reg_list | wc -l | tr -d ' ')" "reg_drop_ref removes all rows with that ref"
assert_contains "$(reg_list)" "workspace:6" "reg_drop_ref leaves other refs"

rm -rf "$FAKE_CMUX" "$FAKE_HOME" "$SPAWN_REGISTRY"
report
