# The original AppleScript backend. Behaviour is frozen — this path is what
# runs when cmux is absent, and it is what brainc/spawn-issue-fixers have been
# exercising for months.

# iTerm is macOS-only and may simply not be installed. Checked before `auto`
# picks this backend, so a Linux box (or a Mac without iTerm) falls through to
# tmux instead of failing inside osascript.
iterm_available() {
  [ "$(uname -s)" = "Darwin" ] || return 1
  [ -x /usr/bin/osascript ] || return 1
  /usr/bin/osascript -e 'exists application id "com.googlecode.iterm2"' 2>/dev/null \
    | grep -q true
}

iterm_spawn() {
  _cwd="$1"; _claude_cmd="$2"
  # Write the command to a temp script so AppleScript doesn't have to quote it.
  _shell_bin="${SHELL:-/bin/zsh}"
  _tmp=$(/usr/bin/mktemp -t spawn-claude.XXXXXX)
  chmod 700 "$_tmp"
  cat > "$_tmp" <<SCRIPT
#!${_shell_bin} -l
cd '$(sc_shell_escape "$_cwd")'
$_claude_cmd
exec ${_shell_bin} -l
SCRIPT

  # Self-delete the temp script after it has been read by the new shell.
  # We can't trap-clean here because the new window owns it. Instead, schedule
  # cleanup once the script starts executing.
  (sleep 30 && rm -f "$_tmp") &
  disown || true

  /usr/bin/osascript \
    -e 'tell application "iTerm"' \
    -e '  activate' \
    -e "  create window with default profile command \"${_shell_bin} ${_tmp}\"" \
    -e 'end tell' >/dev/null
}

# ---------------------------------------------------------------------------
# Post-launch verification. The osascript above returns immediately; the actual
# claude process starts a moment later inside the new window. Two silent-failure
# modes are worth surfacing here rather than leaving the caller to discover them:
#
#   1. The window opened but claude never started (bad PATH, crash on load) — the
#      script's whole reason for pinning $claude_bin. Confirm the process exists.
#   2. The session is running but remote control can't attach, so it never appears
#      in the mobile/desktop app. RC is bridged by a separate `claude daemon`
#      supervisor; a `--rc` spawn does NOT start it. If that daemon isn't running
#      (commonly because a CLI auto-upgrade restarted it — see SKILL.md), the
#      session still runs normally in its own visible iTerm window — it is just not
#      attached to the app for remote control. It is NOT headless.
#
# Skip with SPAWN_NO_VERIFY=1. Never fatal — a spawned session is fully usable in
# its iTerm window without RC-app attachment, and this must not turn a working
# launch into a non-zero exit.
#
# (The SPAWN_NO_VERIFY guard itself now lives at the call site in spawn.sh, not
# here — it is a backend-agnostic switch, not an iTerm-specific one. This
# function is only ever invoked when the guard has already passed.)
iterm_verify() {
  _name="$1"; _cwd="$2"
  sleep 4
  if ps -eo command= | grep -F -- "--name $_name" | grep -Fq -- "--rc"; then
    echo "✓ session '$_name' is running (cwd: $_cwd)"
  else
    echo "⚠ session '$_name' did not start — open the new iTerm window and check for an error." >&2
  fi

  if sc_rc_advisory; then
    echo "ℹ remote control: no 'claude daemon' is running."
    echo "  The session runs normally in its own iTerm window — it is NOT headless."
    echo "  It just won't appear in the mobile/desktop app for remote control until a"
    echo "  daemon is running (it normally respawns on your next interactive 'claude'"
    echo "  launch). See SKILL.md 'Remote control not attaching' if it's still missing."
  fi
  return 0
}
