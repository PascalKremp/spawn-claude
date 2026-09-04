. "$(dirname "$0")/harness.sh"
. "$(dirname "$0")/../scripts/lib/common.sh"
. "$(dirname "$0")/../scripts/lib/cmux.sh"
S="$(dirname "$0")/../scripts/spawn.sh"

# Binary resolution follows the wrapper's chain, honouring the env var first.
# mktemp, not a fixed /tmp/fake-cmux: a hardcoded path would overwrite and then
# `rm -f` whatever already lives there (another checkout's fixture, a real
# file someone left) purely as a side effect of running the tests.
PROBE_BIN="$(mktemp -t fake-cmux-probe.XXXXXX)"
CMUX_CLAUDE_HOOK_CMUX_BIN="$PROBE_BIN"
chmod +x "$PROBE_BIN"
assert_eq "$PROBE_BIN" "$(cmux_bin)" "resolves from CMUX_CLAUDE_HOOK_CMUX_BIN"
unset CMUX_CLAUDE_HOOK_CMUX_BIN; rm -f "$PROBE_BIN"

# Forcing the iterm backend must emit an ABSOLUTE claude path.
out=$("$S" spawn --dry-run --terminal iterm "t" "p" /tmp 2>&1)
assert_contains "$out" "/claude' --rc" "iterm backend pins an absolute claude path"

# Forcing the cmux backend must emit BARE claude — this is what routes through
# the cmux wrapper shim and injects cmux's hook set.
out=$("$S" spawn --dry-run --terminal cmux "t" "p" /tmp 2>&1)
assert_contains "$out" "claude --rc --name 't'" "cmux backend uses bare claude"
assert_contains "$out" "workspace create" "cmux backend shows the workspace create call"

case "$out" in
  */Users/*claude\ --rc*) _fail "cmux backend must not use an absolute path" "bare claude" "$out" ;;
  *) _pass "cmux backend has no absolute claude path" ;;
esac

# --- Fix round 1: C1 (orphaned live session), I2 (no liveness check),
# I3 (silent parse failure), I4 (unvalidated name), I5 (--terminal validated
# too late) --------------------------------------------------------------
#
# These exercise the REAL (non-dry-run) cmux launch path, so two isolation
# devices are used throughout: a fake `cmux` binary (never the real one —
# nothing here can create an actual workspace) and a fake $HOME, so
# sc_accept_trust's write to "~/.claude.json" lands in a throwaway directory
# instead of the developer's real one. SPAWN_REGISTRY is likewise pointed at
# a throwaway file. SPAWN_DRY_RUN=0 overrides harness.sh's blanket dry-run
# default for exactly these invocations, per the harness's own documented
# opt-out.

FAKE_CMUX="$(mktemp -t fake-cmux.XXXXXX)"
FAKE_SENTINEL="$(mktemp -t fake-cmux-sentinel.XXXXXX)"
rm -f "$FAKE_SENTINEL"
cat > "$FAKE_CMUX" <<'FAKECMUX'
#!/usr/bin/env bash
# Emulates just enough of the cmux CLI for the fix-round tests, with
# behaviour steered by env vars so one binary covers every case.
case "$1 $2" in
  "workspace create")
    # Sentinel: proves to the test that THIS binary — not the real cmux CLI —
    # handled the create. Without it the tests only assume their isolation
    # held; see the FAKE_CMUX_SENTINEL assertions below. Recording the full
    # argument list also lets a test inspect what would have been sent (the
    # --description check further down).
    [ -n "${FAKE_CMUX_SENTINEL:-}" ] && printf '%s\n' "$*" >> "$FAKE_CMUX_SENTINEL"
    # Log the --description VALUE on its own, verbatim. It cannot be unpicked
    # from the joined argument list above, because --command legitimately
    # carries the full multi-line prompt through to claude — only the
    # description is supposed to be a collapsed one-liner.
    if [ -n "${FAKE_CMUX_DESC_LOG:-}" ]; then
      _prev=""
      for _a in "$@"; do
        if [ "$_prev" = "--description" ]; then printf '%s' "$_a" > "$FAKE_CMUX_DESC_LOG"; break; fi
        _prev="$_a"
      done
    fi
    printf '%s\n' "${FAKE_CMUX_CREATE_OUTPUT:-OK workspace:99}"
    exit "${FAKE_CMUX_CREATE_EXIT:-0}" ;;
  "workspace list") printf '%s\n' "${FAKE_CMUX_WS_LIST:-}"; exit "${FAKE_CMUX_WS_LIST_EXIT:-0}" ;;
  identify*) exit "${FAKE_CMUX_IDENTIFY_EXIT:-0}" ;;
  ping) exit 0 ;;
  *) exit 0 ;;
esac
FAKECMUX
chmod +x "$FAKE_CMUX"
export FAKE_CMUX_SENTINEL="$FAKE_SENTINEL"

# HARD GATE for everything below this line. The tests that follow run the REAL
# (non-dry-run) launch path and are isolated by CMUX_CLAUDE_HOOK_CMUX_BIN
# alone. cmux_bin() falls through that env var to CMUX_BUNDLED_CLI_PATH, then
# `command -v cmux`, then /Applications/cmux.app — all of which resolve to the
# REAL cmux CLI on a developer machine. If mktemp or chmod +x silently failed
# (or /tmp were mounted noexec) the fake would not be executable, cmux_bin
# would fall through, and `workspace create --dangerously-skip-permissions`
# would run for real. Refuse to continue instead, and blank the bundled-CLI
# rung so a single missing guard cannot reach a live cmux.
[ -x "$FAKE_CMUX" ] || { echo "FATAL: fake cmux not executable — refusing to run live-path tests" >&2; exit 1; }
export CMUX_BUNDLED_CLI_PATH=/nonexistent-cmux

FAKE_HOME="$(mktemp -d -t spawn-fakehome.XXXXXX)"
FAKE_REGISTRY="$(mktemp -t spawn-fakereg.XXXXXX)"

# C1 — a failing `identify` (the post-create window-ref scrape) must not abort
# under set -e/pipefail: the workspace was already created and the claude
# command already sent by this point, so losing the registry row and all
# output here would orphan a live session with no trace.
out=$(HOME="$FAKE_HOME" CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      FAKE_CMUX_IDENTIFY_EXIT=1 SPAWN_REGISTRY="$FAKE_REGISTRY" \
      SPAWN_DRY_RUN=0 SPAWN_NO_VERIFY=1 \
      "$S" spawn --terminal cmux "c1-test" "p" /tmp 2>&1)
rc=$?
assert_eq "0" "$rc" "C1: failing identify does not abort the spawn"
assert_contains "$out" "✓ spawned workspace:99" "C1: success line still prints"
assert_contains "$(cat "$FAKE_REGISTRY" 2>/dev/null)" "c1-test" "C1: registry row still written"

# Isolation proof, not isolation assumption: the fake logs every `workspace
# create` it serves. If this file is empty, the create above was served by
# something else — i.e. the real cmux CLI — and every "safe" test below is a
# live spawn. Assert it rather than trusting the env var took effect.
if [ -s "$FAKE_SENTINEL" ]; then
  _pass "isolation: 'workspace create' was served by the FAKE cmux, not a real one"
else
  _fail "isolation: 'workspace create' was served by the FAKE cmux, not a real one" \
        "sentinel written by the fake" "sentinel empty/missing — a REAL cmux may have run"
fi

# I3 — unparseable `workspace create` output must say a session may exist.
err=$(HOME="$FAKE_HOME" CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      FAKE_CMUX_CREATE_OUTPUT="not the OK line we expect" \
      SPAWN_REGISTRY="$FAKE_REGISTRY" SPAWN_DRY_RUN=0 SPAWN_NO_VERIFY=1 \
      "$S" spawn --terminal cmux "i3-test" "p" /tmp 2>&1 1>/dev/null)
assert_contains "$err" "may already" "I3: parse failure warns a session may be live"

# I4 — a name containing a tab must be rejected before anything is created.
out=$("$S" spawn --dry-run --terminal cmux "$(printf 'bad\tname')" "p" /tmp 2>&1)
rc=$?
assert_eq "1" "$rc" "I4: tab in name is rejected"
assert_contains "$out" "must not contain a tab or newline" "I4: rejection message names the reason"

# I5 — an invalid --terminal must fail before ~/.claude.json is touched. A
# fresh fake $HOME with no pre-existing .claude.json makes "it still doesn't
# exist afterward" an unambiguous check.
FAKE_HOME2="$(mktemp -d -t spawn-fakehome2.XXXXXX)"
HOME="$FAKE_HOME2" SPAWN_DRY_RUN=0 "$S" spawn --terminal bogus "i5-test" "p" /tmp >/dev/null 2>&1
rc=$?
assert_eq "1" "$rc" "I5: invalid --terminal exits 1"
if [ -e "$FAKE_HOME2/.claude.json" ]; then
  _fail "I5: invalid --terminal never touches the trust file" "no .claude.json" "file was created"
else
  _pass "I5: invalid --terminal never touches the trust file"
fi

# I2 — the liveness check is non-fatal and warns when nothing with a
# matching --name/--rc is running (true here — nothing real was launched by
# any of the tests above).
out=$(cmux_verify "no-such-process-xyz" 2>&1)
rc=$?
assert_eq "0" "$rc" "I2: cmux_verify never fails the script"
assert_contains "$out" "did not start" "I2: cmux_verify warns when no matching process is found"

# C1 (registry-write half) — a workspace was created and claude already sent
# by the time reg_append runs; if THAT fails (full disk, unwritable state
# dir, ...) the spawn must still be reported, not lost. Point SPAWN_REGISTRY
# at a file inside a read-only directory so reg_append's `printf >>` fails.
NOWRITE_DIR="$(mktemp -d -t spawn-nowrite.XXXXXX)"
chmod 555 "$NOWRITE_DIR"
out=$(HOME="$FAKE_HOME" CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      SPAWN_REGISTRY="$NOWRITE_DIR/spawns.tsv" \
      SPAWN_DRY_RUN=0 SPAWN_NO_VERIFY=1 \
      "$S" spawn --terminal cmux "reg-fail-test" "p" /tmp 2>&1)
rc=$?
assert_eq "0" "$rc" "C1 (registry): unwritable registry does not abort the spawn"
assert_contains "$out" "failed to record it in the registry" "C1 (registry): warns the session was not logged"
assert_contains "$out" "✓ spawned workspace:99" "C1 (registry): success line still prints"
chmod 755 "$NOWRITE_DIR"

# --- Fix round: a multi-line prompt became the entire workspace description --
#
# The description was `printf '%s' "$prompt" | cut -c1-120`, and `cut -c`
# truncates each LINE, not the string — so a multi-line prompt kept every one
# of its lines. skills/spawn-issue-fixers/scripts/spawn-fixer.sh passes a
# ~15-line heredoc, so every issue-fixer workspace was labelled with its whole
# prompt instead of a one-line summary. Fixed by collapsing newlines to spaces
# before truncating.
#
# The description is only visible on the real create call (the dry-run line
# doesn't print it), so this reads it back off the fake's argument log.
FAKE_DESC_LOG="$(mktemp -t fake-cmux-desc.XXXXXX)"
export FAKE_CMUX_DESC_LOG="$FAKE_DESC_LOG"

: > "$FAKE_DESC_LOG"
MULTILINE_PROMPT="$(printf 'Fix issue #123: the button is broken\nContext line two\nContext line three\nContext line four')"
HOME="$FAKE_HOME" CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
  SPAWN_REGISTRY="$FAKE_REGISTRY" SPAWN_DRY_RUN=0 SPAWN_NO_VERIFY=1 \
  "$S" spawn --terminal cmux "m5-test" "$MULTILINE_PROMPT" /tmp >/dev/null 2>&1

# Pre-fix this was 4 — one description line per prompt line.
assert_eq "1" "$(awk 'END { print NR }' "$FAKE_DESC_LOG")" "M5: a 4-line prompt yields a ONE-LINE description"
assert_eq "Fix issue #123: the button is broken Context line two Context line three Context line four" \
          "$(cat "$FAKE_DESC_LOG")" "M5: newlines are collapsed to spaces, not kept"

# Truncation must apply to the COLLAPSED line: a long multi-line prompt must
# not smuggle extra text past the 120-char cap by splitting across lines.
: > "$FAKE_DESC_LOG"
LONG_PROMPT="$(awk 'BEGIN { for (i = 0; i < 40; i++) print "line " i " of a long multi-line prompt with plenty of text" }')"
HOME="$FAKE_HOME" CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
  SPAWN_REGISTRY="$FAKE_REGISTRY" SPAWN_DRY_RUN=0 SPAWN_NO_VERIFY=1 \
  "$S" spawn --terminal cmux "m5-long" "$LONG_PROMPT" /tmp >/dev/null 2>&1

assert_eq "1" "$(awk 'END { print NR }' "$FAKE_DESC_LOG")" "M5: a 40-line prompt still yields a one-line description"
_desc=$(cat "$FAKE_DESC_LOG"); _len=${#_desc}
if [ "$_len" -le 120 ]; then
  _pass "M5: the collapsed description is truncated to 120 chars (${_len})"
else
  _fail "M5: the collapsed description is truncated to 120 chars" "<= 120" "$_len"
fi

# --- SPAWN_NO_VERIFY had the same fail-open shape as SPAWN_DRY_RUN ---------
#
# Its two guards were `[[ "${SPAWN_NO_VERIFY:-0}" -ne 1 ]]`, and they run AFTER
# the workspace and the claude session already exist. Under `set -u` a
# non-integer value makes that arithmetic comparison abort with "yes: unbound
# variable" — so a perfectly successful spawn exited 1 immediately after
# printing "✓ spawned". Everything past cmux_spawn is deliberately non-fatal
# precisely so a live session is never reported as a failure, so this switch is
# now normalised the same way.
out=$(HOME="$FAKE_HOME" CMUX_CLAUDE_HOOK_CMUX_BIN="$FAKE_CMUX" \
      SPAWN_REGISTRY="$FAKE_REGISTRY" SPAWN_DRY_RUN=0 SPAWN_NO_VERIFY=yes \
      "$S" spawn --terminal cmux "nv-test" "p" /tmp 2>&1)
rc=$?
assert_eq "0" "$rc" "SPAWN_NO_VERIFY=yes does not turn a successful spawn into exit 1"
assert_contains "$out" "✓ spawned workspace:99" "SPAWN_NO_VERIFY=yes still reports the spawn"
case "$out" in
  *"unbound variable"*) _fail "SPAWN_NO_VERIFY=yes never trips set -u" "no unbound-variable error" "$out" ;;
  *) _pass "SPAWN_NO_VERIFY=yes never trips set -u" ;;
esac

rm -rf "$FAKE_CMUX" "$FAKE_SENTINEL" "$FAKE_DESC_LOG""$FAKE_HOME" "$FAKE_HOME2" "$FAKE_REGISTRY" "$NOWRITE_DIR"

report
