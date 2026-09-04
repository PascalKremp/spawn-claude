# cmux backend. Spawns into a cmux workspace instead of an iTerm window, so the
# session inherits cmux's injected hook set (status, progress, feed,
# notifications, auto-name, session restore).

# Mirrors resolve_hook_cmux_bin() in cmux-claude-wrapper:864. Steps 1-2 point
# into the app bundle and can go stale across an app update; step 3 is why
# /opt/homebrew/bin/cmux is symlinked to the bundled CLI.
cmux_bin() {
  if [ -n "${CMUX_CLAUDE_HOOK_CMUX_BIN:-}" ] && [ -x "${CMUX_CLAUDE_HOOK_CMUX_BIN}" ]; then
    printf '%s' "$CMUX_CLAUDE_HOOK_CMUX_BIN"; return 0
  fi
  if [ -n "${CMUX_BUNDLED_CLI_PATH:-}" ] && [ -x "${CMUX_BUNDLED_CLI_PATH}" ]; then
    printf '%s' "$CMUX_BUNDLED_CLI_PATH"; return 0
  fi
  _b=$(command -v cmux 2>/dev/null || true)
  if [ -n "$_b" ]; then printf '%s' "$_b"; return 0; fi
  _b=/Applications/cmux.app/Contents/Resources/bin/cmux
  if [ -x "$_b" ]; then printf '%s' "$_b"; return 0; fi
  return 1
}

# CMUX_QUIET=1 suppresses the legacy-alias deprecation notice, which would
# otherwise land on stdout and corrupt every parse in this file.
cmux_run() {
  _b=$(cmux_bin) || { echo "Error: cmux CLI not found." >&2; return 1; }
  CMUX_QUIET=1 "$_b" "$@"
}

cmux_available() {
  [ -n "${CMUX_SOCKET_PATH:-}" ] || return 1
  cmux_bin >/dev/null 2>&1 || return 1
  cmux_run ping >/dev/null 2>&1
}

# cmux_ws_list — capture `cmux workspace list` once. Exit 0 with the listing on
# stdout, or 2 if the CALL ITSELF failed. Callers that reconcile several rows
# should call this once and match with cmux_ws_match, rather than paying one
# cmux round trip per row.
cmux_ws_list() {
  cmux_run workspace list 2>/dev/null || return 2
}

# cmux_ws_match <listing> <ref> — 0 present, 1 absent. Pure text, no cmux call.
#
# `grep -c`, not `grep -q`, ON PURPOSE. `grep -q` exits the moment it matches,
# which SIGPIPEs whatever is still writing into it; under this script's
# `set -o pipefail` the pipeline then returns 141 EVEN ON A SUCCESSFUL MATCH,
# once the listing exceeds the 64K pipe buffer. That is exactly how `list`
# came to drop live sessions (reproduced: a 200k-line listing containing the
# ref returned 141 from both the original `cmux_run ... | grep -q` form and
# from the `printf '%s\n' "$captured" | grep -q` form). `grep -c` reads its
# input to EOF, so nothing can be SIGPIPEd; `|| true` absorbs grep's exit 1
# for "no match", which is a legitimate answer here and not an error.
#
# The ref is matched as a whitespace-delimited field so workspace:9 never
# matches inside workspace:94.
# Variables here are prefixed because none of these helpers can declare
# `local` without breaking sh compatibility, and callers loop over registry
# rows into short names — an unprefixed `_n` here would clobber the caller's
# row-name variable mid-iteration.
cmux_ws_match() {
  _wsm_count=$(printf '%s\n' "$1" | grep -Ec "(^|[[:space:]])$2([[:space:]]|$)" || true)
  [ "${_wsm_count:-0}" -gt 0 ]
}

# cmux_ws_exists <ref> — 0 present, 1 absent, 2 the cmux call failed.
#
# The rc-2 case is load-bearing and must not be collapsed into "absent":
# callers use this both to hide rows (`list`) and to DELETE rows (spawn's
# stale-name prune). Treating an unreachable cmux as proof a workspace is gone
# would hide live sessions and prune live registry rows.
cmux_ws_exists() {
  _wse_list=$(cmux_ws_list) || return 2
  cmux_ws_match "$_wse_list" "$1"
}

# cmux_spawn <name> <description> <cwd> <command> — prints the new workspace ref.
# --focus false keeps the caller's view; --command sends text+Enter to the new shell.
cmux_spawn() {
  _out=$(cmux_run workspace create \
    --name "$1" --description "$2" --cwd "$3" \
    --focus false --command "$4" 2>&1) || {
      printf '%s\n' "$_out" >&2; return 1; }
  # Success output is a single line: "OK workspace:61"
  _ref=$(printf '%s\n' "$_out" | sed -n 's/^OK \(workspace:[0-9][0-9]*\)$/\1/p')
  if [ -z "$_ref" ]; then
    echo "Error: could not parse workspace ref from cmux output:" >&2
    printf '%s\n' "$_out" >&2
    echo "Note: the workspace — and the claude session inside it — may already" >&2
    echo "      have been created despite this parse failure; check" >&2
    echo "      'cmux workspace list' before retrying." >&2
    return 1
  fi
  printf '%s' "$_ref"
}

# ---------------------------------------------------------------------------
# Post-launch verification for the cmux backend, mirroring iterm_verify's two
# checks: process liveness, then the RC-daemon advisory.
#
# The liveness check matters even though cmux_spawn already got a positive
# "OK workspace:N" reply: that reply only confirms the WORKSPACE was created
# and the command text was sent, not that `claude` itself started inside it.
# Bare `claude` resolves through cmux's shell integration (function -> shim ->
# wrapper); if that resolution fails, "command not found" scrolls past in an
# unfocused workspace nobody is watching, and without this check the caller
# would only ever see "✓ spawned" with nothing to contradict it.
#
# Skip with SPAWN_NO_VERIFY=1 (guarded at the call site in spawn.sh, same as
# the iTerm path). Never fatal, for the same reason iterm_verify isn't: a
# spawned workspace is still there to inspect by hand even when this check
# can't confirm claude started.
cmux_verify() {
  _n="$1"
  sleep 4
  if ps -eo command= | grep -F -- "--name $_n" | grep -Fq -- "--rc"; then
    echo "✓ session '$_n' is running"
  else
    echo "⚠ session '$_n' did not start — bare 'claude' depends on cmux's shell" >&2
    echo "  integration resolving it; check 'spawn.sh read $_n' for a 'command not" >&2
    echo "  found' or similar startup error." >&2
  fi

  if sc_rc_advisory; then
    echo "ℹ remote control: no 'claude daemon' is running."
    echo "  The session is running normally in its cmux workspace \"$_n\" — cmux's"
    echo "  own hooks (status, progress, feed, notifications) do not depend on this"
    echo "  daemon and are unaffected. It just won't appear in the mobile/desktop app"
    echo "  for remote control until a daemon is running (it normally respawns on"
    echo "  your next interactive 'claude' launch). See SKILL.md 'Remote control not"
    echo "  attaching' if it's still missing."
  fi
  return 0
}
