. "$(dirname "$0")/harness.sh"
S="$(dirname "$0")/../scripts/spawn.sh"
export SPAWN_REGISTRY="$(mktemp -t spawnreg.XXXXXX)"
rm -f "$SPAWN_REGISTRY"

# Defense in depth: this machine may be running inside a real cmux session
# (CMUX_SOCKET_PATH set to a live socket). Every check in this file relies on
# the dry-run short-circuit happening before cmux is ever touched, but unset
# the real socket path too so a bug in that gating fails safe (cmux_available
# requires CMUX_SOCKET_PATH non-empty) instead of silently reaching a live
# workspace.
unset CMUX_SOCKET_PATH

# Unknown target must fail before any cmux call is attempted.
assert_exit 2 "read on unknown target exits 2" -- "$S" read no-such-session

# Dry-run must print the exact cmux command and mutate nothing.
printf '%s\t%s\t%s\t%s\t%s\n' "2026-08-10T00:00:00Z" "demo" "workspace:99" "window:1" "/tmp" > "$SPAWN_REGISTRY"

out=$("$S" read demo --dry-run 2>&1)
assert_contains "$out" "read-screen" "read dry-run shows read-screen"
assert_contains "$out" "workspace:99" "read dry-run resolves the name to a ref"

out=$("$S" tell demo "hello there" --dry-run 2>&1)
# "send" alone would also match inside "send-key" — assert the exact line so
# a missing plain `send` call can actually fail this check.
assert_contains "$out" "cmux send --workspace workspace:99 -- hello there" "tell dry-run shows the exact send line"
assert_contains "$out" "send-key" "tell dry-run also sends Enter (cmux send does NOT append it)"

out=$("$S" close demo --dry-run 2>&1)
assert_contains "$out" "workspace close" "close dry-run shows workspace close"

# --- Fix round: C1 (tell truncates unquoted multi-word text), I2 (read/close
# let a stray positional silently retarget), I3 (key had no --dry-run), I4
# (SPAWN_DRY_RUN wasn't honoured by read/tell/key/close) -------------------

# C1 — an unquoted multi-word message must be rejected, not silently
# truncated to the last word or joined back together.
out=$("$S" tell demo hello there --dry-run 2>&1); rc=$?
assert_eq "1" "$rc" "C1: tell rejects an unquoted multi-word message"
assert_contains "$out" "too many arguments" "C1: tell's rejection names the problem"
assert_contains "$out" "quote the message" "C1: tell's rejection tells the caller to quote it"

# I2 — a stray trailing positional on read/close must be rejected, not
# silently become the new target.
out=$("$S" read demo garbage --dry-run 2>&1); rc=$?
assert_eq "1" "$rc" "I2: read rejects a stray trailing positional"
assert_contains "$out" "too many arguments" "I2: read's rejection names the problem"

out=$("$S" close demo garbage --dry-run 2>&1); rc=$?
assert_eq "1" "$rc" "I2: close rejects a stray trailing positional"
assert_contains "$out" "too many arguments" "I2: close's rejection names the problem"

# I3 — key must support --dry-run like every other verb that drives a live
# session.
out=$("$S" key demo up --dry-run 2>&1)
assert_contains "$out" "cmux send-key --workspace workspace:99 up" "I3: key dry-run shows the exact send-key line"

# I4 — SPAWN_DRY_RUN=1 alone (no --dry-run flag) must be a real global kill
# switch for every lifecycle verb, not just spawn. harness.sh already exports
# SPAWN_DRY_RUN=1, so none of these pass --dry-run explicitly; before the
# fix each of read/tell/key/close hardcoded dry=0 and would fall through to
# require_cmux (and, worse, a live cmux call) regardless of this env var.
out=$("$S" read demo 2>&1)
assert_contains "$out" "read-screen" "I4: SPAWN_DRY_RUN=1 alone makes read a dry-run"

out=$("$S" tell demo "hello there" 2>&1)
assert_contains "$out" "cmux send --workspace workspace:99 -- hello there" "I4: SPAWN_DRY_RUN=1 alone makes tell a dry-run"

out=$("$S" key demo up 2>&1)
assert_contains "$out" "cmux send-key --workspace workspace:99 up" "I4: SPAWN_DRY_RUN=1 alone makes key a dry-run"

out=$("$S" close demo 2>&1)
assert_contains "$out" "workspace close" "I4: SPAWN_DRY_RUN=1 alone makes close a dry-run"

rm -f "$SPAWN_REGISTRY"
report
