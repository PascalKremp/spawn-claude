. "$(dirname "$0")/harness.sh"
S="$(dirname "$0")/../scripts/spawn.sh"
export SPAWN_REGISTRY="$(mktemp -t spawnreg.XXXXXX)"
printf '%s\t%s\t%s\t%s\t%s\n' "2026-08-10T00:00:00Z" "demo" "workspace:99" "window:1" "/tmp" > "$SPAWN_REGISTRY"

# Defense in depth, same rationale as test-verbs.sh: unset any real cmux
# socket so a bug in the dry-run/resolve gating fails safe instead of
# reaching a live workspace.
unset CMUX_SOCKET_PATH

# --- dry-run: resolves the target, names its polling mechanism, shows the
# effective timeout, and never polls -----------------------------------

out=$("$S" wait demo --dry-run 2>&1)
assert_contains "$out" "workspace:99" "wait dry-run resolves the target"
assert_contains "$out" "list-status" "wait dry-run names its polling mechanism (cmux list-status, not screen-scraping)"
assert_contains "$out" "claude_code=Idle" "wait dry-run names the field it polls for"
assert_contains "$out" "300" "wait dry-run shows the default timeout"

out=$("$S" wait demo --timeout 42 --dry-run 2>&1)
assert_contains "$out" "42" "wait honours --timeout"

assert_exit 2 "wait on unknown target exits 2" -- "$S" wait no-such --dry-run

# --- real polling, via a fake cmux binary -------------------------------
#
# `require_cmux` needs cmux_available() to see a non-empty CMUX_SOCKET_PATH,
# a resolvable cmux binary, and a successful `ping` — all satisfied here by
# a fake binary, never the real cmux CLI. SPAWN_DRY_RUN=0 opts out of
# harness.sh's blanket dry-run default for exactly these invocations, per
# its documented escape hatch. SPAWN_WAIT_INTERVAL=1 keeps polling fast
# without changing the production default (5s).

FAKE_CMUX="$(mktemp -t fake-cmux-wait.XXXXXX)"
cat > "$FAKE_CMUX" <<'FAKECMUX'
#!/usr/bin/env bash
case "$1" in
  list-status) printf '%s\n' "${FAKE_CMUX_STATUS:-}"; exit 0 ;;
  ping) exit 0 ;;
  *) exit 0 ;;
esac
FAKECMUX
chmod +x "$FAKE_CMUX"

# Same hard gate as test-cmux.sh. Everything below runs with SPAWN_DRY_RUN=0
# and is isolated by CMUX_CLAUDE_HOOK_CMUX_BIN alone; cmux_bin() falls through
# that to CMUX_BUNDLED_CLI_PATH, `command -v cmux`, and /Applications/cmux.app,
# all of which resolve to the real CLI here. `wait` only ever issues read-only
# `list-status`, so this is hygiene rather than a live-spawn risk — but the
# isolation must not depend on which verb happens to be under test.
[ -x "$FAKE_CMUX" ] || { echo "FATAL: fake cmux not executable — refusing to run live-path tests" >&2; exit 1; }
export CMUX_BUNDLED_CLI_PATH=/nonexistent-cmux

# Idle detected on the very first poll -> exit 0, no sleep needed.
out=$(CMUX_SOCKET_PATH=fake-socket CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      FAKE_CMUX_STATUS="claude_code=Idle icon=pause.circle.fill color=#8E8E93" \
      SPAWN_DRY_RUN=0 SPAWN_WAIT_INTERVAL=1 \
      "$S" wait demo --timeout 5 2>&1)
rc=$?
assert_eq "0" "$rc" "wait exits 0 once claude_code=Idle is reported"
assert_contains "$out" "is idle" "wait's success message names the target"

# Never goes idle -> exit 124, and the wall-clock wait actually respects the
# configured --timeout (not e.g. returning immediately or hanging past it).
start=$(date +%s)
out=$(CMUX_SOCKET_PATH=fake-socket CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      FAKE_CMUX_STATUS="claude_code=Running icon=bolt.fill color=#4C8DFF" \
      SPAWN_DRY_RUN=0 SPAWN_WAIT_INTERVAL=1 \
      "$S" wait demo --timeout 2 2>&1)
rc=$?
end=$(date +%s)
waited=$((end - start))
assert_eq "124" "$rc" "wait exits 124 when the session never goes idle"
assert_contains "$out" "timed out after 2s" "wait's timeout message names the effective timeout"
if [ "$waited" -ge 2 ]; then
  _pass "wait actually waits out the configured timeout (${waited}s)"
else
  _fail "wait actually waits out the configured timeout" ">= 2s" "${waited}s"
fi

# Defensive parse: no `claude_code` key at all must be treated as not-idle,
# never as idle — a status-reporting gap must not make `wait` return success
# spuriously.
out=$(CMUX_SOCKET_PATH=fake-socket CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      FAKE_CMUX_STATUS="icon=bolt.fill color=#4C8DFF" \
      SPAWN_DRY_RUN=0 SPAWN_WAIT_INTERVAL=1 \
      "$S" wait demo --timeout 2 2>&1)
rc=$?
assert_eq "124" "$rc" "wait treats a missing claude_code key as not-idle"

# Field-boundary parse: claude_code=Idle must be matched as a whole field,
# not a loose substring — neither a different key ending in the same text
# nor a value merely prefixed with "Idle" should count.
out=$(CMUX_SOCKET_PATH=fake-socket CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      FAKE_CMUX_STATUS="other_claude_code=Idle icon=bolt.fill" \
      SPAWN_DRY_RUN=0 SPAWN_WAIT_INTERVAL=1 \
      "$S" wait demo --timeout 2 2>&1)
rc=$?
assert_eq "124" "$rc" "wait does not match claude_code=Idle as a loose substring of another key"

out=$(CMUX_SOCKET_PATH=fake-socket CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      FAKE_CMUX_STATUS="claude_code=IdleButNotReally icon=bolt.fill" \
      SPAWN_DRY_RUN=0 SPAWN_WAIT_INTERVAL=1 \
      "$S" wait demo --timeout 2 2>&1)
rc=$?
assert_eq "124" "$rc" "wait requires an exact Idle value, not an Idle-prefixed one"

# --- Fix round: SPAWN_WAIT_INTERVAL / --timeout validation --------------
#
# C1: SPAWN_WAIT_INTERVAL=0 was an infinite busy-loop that ignored --timeout
# entirely — `sleep 0` returns instantly and `elapsed=$((elapsed + 0))`
# never advances, so the loop condition never turns false. I2: a negative or
# non-numeric interval reached an unguarded `sleep`, which dies under
# set -euo pipefail and leaks a raw "sleep: invalid time interval: ..."
# message with an exit code outside wait's documented 0/124 contract.
# Fixed by require_positive_int validating once, before the loop, rather
# than silently clamping to the default.

# interval=0 must fail immediately with exit 1, not spin forever. Proven by
# measuring wall-clock time — nothing in this harness would kill a runaway
# loop, so "the test finished" is only meaningful because we time it.
start=$(date +%s)
out=$(CMUX_SOCKET_PATH=fake-socket CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      FAKE_CMUX_STATUS="claude_code=Running" \
      SPAWN_DRY_RUN=0 SPAWN_WAIT_INTERVAL=0 \
      "$S" wait demo --timeout 3 2>&1)
rc=$?
end=$(date +%s)
waited=$((end - start))
assert_eq "1" "$rc" "SPAWN_WAIT_INTERVAL=0 exits 1 instead of busy-looping"
assert_contains "$out" "SPAWN_WAIT_INTERVAL must be a positive whole number" "SPAWN_WAIT_INTERVAL=0 names the offending variable"
assert_contains "$out" "got '0'" "SPAWN_WAIT_INTERVAL=0 message names the received value"
if [ "$waited" -le 2 ]; then
  _pass "SPAWN_WAIT_INTERVAL=0 terminates immediately (${waited}s), proving it didn't busy-loop"
else
  _fail "SPAWN_WAIT_INTERVAL=0 terminates immediately" "<= 2s" "${waited}s"
fi

# Negative interval must fail cleanly with wait's own message, never a raw
# `sleep: invalid time interval` leaking from an unguarded sleep.
out=$(CMUX_SOCKET_PATH=fake-socket CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      FAKE_CMUX_STATUS="claude_code=Running" \
      SPAWN_DRY_RUN=0 SPAWN_WAIT_INTERVAL=-1 \
      "$S" wait demo --timeout 3 2>&1)
rc=$?
assert_eq "1" "$rc" "SPAWN_WAIT_INTERVAL=-1 exits 1 with a clean error"
assert_contains "$out" "SPAWN_WAIT_INTERVAL must be a positive whole number" "SPAWN_WAIT_INTERVAL=-1 names the offending variable"
case "$out" in
  *"invalid time interval"*) _fail "SPAWN_WAIT_INTERVAL=-1 never reaches a raw sleep error" "no sleep error" "$out" ;;
  *) _pass "SPAWN_WAIT_INTERVAL=-1 never reaches a raw sleep error" ;;
esac

# Non-numeric interval — same contract as negative.
out=$(CMUX_SOCKET_PATH=fake-socket CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      FAKE_CMUX_STATUS="claude_code=Running" \
      SPAWN_DRY_RUN=0 SPAWN_WAIT_INTERVAL=abc \
      "$S" wait demo --timeout 3 2>&1)
rc=$?
assert_eq "1" "$rc" "SPAWN_WAIT_INTERVAL=abc exits 1 with a clean error"
assert_contains "$out" "SPAWN_WAIT_INTERVAL must be a positive whole number" "SPAWN_WAIT_INTERVAL=abc names the offending variable"

# Non-numeric --timeout must not masquerade as a legitimate timeout result.
# Previously: polling was skipped entirely (the loop condition itself never
# ran) and wait printed "timed out after abcs" with exit 124 — a bad input
# disguised as a real result. --dry-run is enough here since validation now
# happens before the dry-run branch, so no fake cmux is needed.
out=$("$S" wait demo --timeout abc --dry-run 2>&1)
rc=$?
assert_eq "1" "$rc" "--timeout abc exits 1 instead of faking a timeout result"
assert_contains "$out" "--timeout must be a positive whole number" "--timeout abc names the offending flag"
case "$out" in
  *"timed out after"*) _fail "--timeout abc never reports a fake timeout result" "no fake timeout message" "$out" ;;
  *) _pass "--timeout abc never reports a fake timeout result" ;;
esac

# --- Fix round 2: leading-zero interval values are octal in arithmetic --
#
# require_positive_int's glob accepts any all-digit string, including
# leading-zero ones (rejecting "010" would over-reject a reasonable
# zero-padded input, and `sleep`/`[ -lt ]` already treat it as decimal). But
# the loop's `elapsed=$((elapsed + interval))` is a bash arithmetic context,
# which reads a leading zero as octal: "08"/"09" have no octal digit 8/9 and
# crash with "value too great for base"; "020" silently evaluates to decimal
# 16 instead of 20, desyncing `elapsed` from what `sleep` (which parses its
# argument as decimal, same as `[ -lt ]`) actually did. Fixed by forcing
# base-10 interpretation at the one arithmetic use site:
# `elapsed=$((elapsed + 10#$interval))`.
#
# These all need a real sleep to exercise the line where the crash/drift
# used to happen (it's the *loop body's* arithmetic, reached only after a
# non-idle status and its sleep), so unlike the fix-round-1 tests above
# these cost real wall-clock seconds — measured explicitly below, same
# approach as the interval=0 termination proof.

# interval=08: bash reads "08" as octal and has no digit 8, so pre-fix this
# died mid-loop with "value too great for base" (confirmed by reproducing
# against the pre-10# code: exit 1, that exact message, after the first
# sleep). Post-fix it must reach the ordinary 124 timeout path instead.
out=$(CMUX_SOCKET_PATH=fake-socket CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      FAKE_CMUX_STATUS="claude_code=Running" \
      SPAWN_DRY_RUN=0 SPAWN_WAIT_INTERVAL=08 \
      "$S" wait demo --timeout 5 2>&1)
rc=$?
assert_eq "124" "$rc" "SPAWN_WAIT_INTERVAL=08 reaches the normal timeout path, not a crash"
case "$out" in
  *"value too great for base"*) _fail "SPAWN_WAIT_INTERVAL=08 never hits the octal arithmetic crash" "no arithmetic error" "$out" ;;
  *) _pass "SPAWN_WAIT_INTERVAL=08 never hits the octal arithmetic crash" ;;
esac

# interval=09: same failure mode ("09" has no octal digit 9 either).
out=$(CMUX_SOCKET_PATH=fake-socket CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      FAKE_CMUX_STATUS="claude_code=Running" \
      SPAWN_DRY_RUN=0 SPAWN_WAIT_INTERVAL=09 \
      "$S" wait demo --timeout 5 2>&1)
rc=$?
assert_eq "124" "$rc" "SPAWN_WAIT_INTERVAL=09 reaches the normal timeout path, not a crash"
case "$out" in
  *"value too great for base"*) _fail "SPAWN_WAIT_INTERVAL=09 never hits the octal arithmetic crash" "no arithmetic error" "$out" ;;
  *) _pass "SPAWN_WAIT_INTERVAL=09 never hits the octal arithmetic crash" ;;
esac

# interval=020 must behave exactly like interval=20: `sleep` already parses
# "020" as decimal 20 (confirmed separately: `sleep 020` takes ~20s, same as
# `sleep 20`), so the only thing left to prove is that `elapsed` now tracks
# 20-per-iteration too, not the octal-16-per-iteration it used to. --timeout
# 17 is chosen so the two models diverge in ITERATION COUNT, not just the
# reported number: correctly counting elapsed as 20 crosses 17 after a
# single sleep (~20s wall, one real `sleep 020`), whereas the old buggy
# +16-per-iteration accounting would still read 16 < 17 after that first
# sleep and require a second ~20s sleep before crossing 17 (~40s wall) — the
# "silent divergence" from the review, reproduced here as a measured,
# real-time iteration count rather than an inferred one.
start=$(date +%s)
out=$(CMUX_SOCKET_PATH=fake-socket CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      FAKE_CMUX_STATUS="claude_code=Running" \
      SPAWN_DRY_RUN=0 SPAWN_WAIT_INTERVAL=020 \
      "$S" wait demo --timeout 17 2>&1)
rc=$?
end=$(date +%s)
waited=$((end - start))
assert_eq "124" "$rc" "SPAWN_WAIT_INTERVAL=020 exits 124 (still an ordinary timeout, not a crash)"
assert_contains "$out" "timed out after 17s" "SPAWN_WAIT_INTERVAL=020 reports the requested timeout, not a drifted one"
if [ "$waited" -ge 15 ] && [ "$waited" -le 30 ]; then
  _pass "SPAWN_WAIT_INTERVAL=020 takes one ~20s sleep like =20 would (${waited}s), not the ~40s two-sleep drift the octal bug caused"
else
  _fail "SPAWN_WAIT_INTERVAL=020 behaves like a single =20 interval" "15-30s (one sleep)" "${waited}s"
fi

rm -f "$FAKE_CMUX"
rm -f "$SPAWN_REGISTRY"
report
