# tmux backend — the portable one. Works anywhere tmux runs (Linux, macOS, BSD,
# over SSH), needs no GUI and no app bundle, so it is what makes this skill
# useful off a Mac with iTerm.
#
# Unlike the iTerm backend (fire-and-forget into a visible window), tmux
# sessions are detached and inspectable, so it supports the same lifecycle
# verbs as cmux: read, tell, key, wait, close.
#
# Refs are spelled `tmux:<session>` so the registry — and therefore every verb —
# can tell a tmux row from a cmux `workspace:N` row without a schema change.

TMUX_SESSION_PREFIX="${SPAWN_TMUX_PREFIX:-spawn}"

tmux_bin() {
  command -v tmux 2>/dev/null
}

tmux_available() {
  tmux_bin >/dev/null 2>&1 || return 1
  # A tmux server need not be running yet; `tmux ls` failing with "no server"
  # is fine, the binary being usable is what matters.
  tmux_bin >/dev/null 2>&1
}

tmux_run() {
  _b=$(tmux_bin) || { echo "Error: tmux not found on PATH." >&2; return 1; }
  "$_b" "$@"
}

# tmux session names cannot contain ':' or '.' (both are address separators),
# and a leading '-' would be read as a flag. Everything else is mapped to '-'
# so an arbitrary task name still yields an addressable session.
# NOTE ON TARGETS: session-level commands (has-session, kill-session) take
# "=<name>"; pane-level commands (send-keys, capture-pane, list-panes) need
# "=<name>:" — without the trailing colon tmux answers "can't find pane".
# The "=" is not optional: it forces an exact match, so a session named
# "spawn-demo" can never be driven by a command aimed at "spawn-demo-task".
tmux_session_name() {
  printf '%s' "$TMUX_SESSION_PREFIX-$1" \
    | tr ':.' '--' \
    | sed 's/[^A-Za-z0-9_-]/-/g; s/^-*//'
}

tmux_ws_list() {
  tmux_run list-sessions -F '#{session_name}' 2>/dev/null || return 0
}

# 0 present, 1 absent, 2 the call itself failed — same tri-state contract as
# cmux_ws_exists, because cmd_list uses it to decide whether to DELETE a row
# and "tmux is unreachable" must never be mistaken for "the session is gone".
tmux_ws_exists() {
  _s="${1#tmux:}"
  if ! tmux_bin >/dev/null 2>&1; then return 2; fi
  if tmux_run has-session -t "=$_s" 2>/dev/null; then return 0; fi
  return 1
}

# tmux_spawn <name> <description> <cwd> <command> — prints the ref.
# The session is created detached (-d) so the caller's terminal is untouched,
# matching cmux's --focus false.
tmux_spawn() {
  _name="$1"; _desc="$2"; _cwd="$3"; _cmd="$4"
  _s=$(tmux_session_name "$_name")

  if tmux_run has-session -t "=$_s" 2>/dev/null; then
    echo "Error: a tmux session named '$_s' already exists." >&2
    echo "       Close it first (spawn.sh close $_name) or spawn under a different name." >&2
    return 1
  fi

  # Start an interactive shell, then send the command into it, rather than
  # running claude as the session's command directly: when claude exits the
  # shell stays, so the scrollback is still readable with `spawn.sh read`
  # instead of the session vanishing with its output.
  if ! _out=$(tmux_run new-session -d -s "$_s" -c "$_cwd" 2>&1); then
    printf '%s\n' "$_out" >&2
    return 1
  fi
  # -l sends the text literally, so no character in the prompt is interpreted
  # as a tmux key name.
  tmux_run send-keys -t "=$_s:" -l "$_cmd" || return 1
  tmux_run send-keys -t "=$_s:" Enter || return 1
  printf 'tmux:%s' "$_s"
}

# tmux_read <session> [lines] [scrollback]
tmux_read() {
  _s="${1#tmux:}"; _lines="$2"; _scroll="$3"
  if [ "$_scroll" = "1" ]; then
    tmux_run capture-pane -p -S - -t "=$_s:"
  elif [ -n "$_lines" ]; then
    tmux_run capture-pane -p -S "-$_lines" -t "=$_s:"
  else
    tmux_run capture-pane -p -t "=$_s:"
  fi
}

tmux_tell() {
  _s="${1#tmux:}"; _text="$2"
  tmux_run send-keys -t "=$_s:" -l "$_text" || return 1
  tmux_run send-keys -t "=$_s:" Enter
}

# cmux spells keys lowercase (enter, escape, ctrl-c); tmux wants Enter, Escape,
# C-c. Map the common ones so a caller can use one spelling on both backends,
# and pass anything else through untouched so native tmux key names still work.
tmux_key() {
  _s="${1#tmux:}"; _k="$2"
  case "$_k" in
    enter|Enter|return)    _k=Enter ;;
    escape|Escape|esc)     _k=Escape ;;
    tab|Tab)               _k=Tab ;;
    space|Space)           _k=Space ;;
    up|Up)                 _k=Up ;;
    down|Down)             _k=Down ;;
    left|Left)             _k=Left ;;
    right|Right)           _k=Right ;;
    backspace|BSpace)      _k=BSpace ;;
    ctrl-c|Ctrl-C|C-c)     _k=C-c ;;
    ctrl-d|Ctrl-D|C-d)     _k=C-d ;;
    ctrl-r|Ctrl-R|C-r)     _k=C-r ;;
  esac
  tmux_run send-keys -t "=$_s:" "$_k"
}

tmux_close() {
  _s="${1#tmux:}"
  tmux_run kill-session -t "=$_s"
}

# tmux_claude_running <task-name> — is that spawned session's claude alive?
# Used by `wait` on the tmux backend.
#
# Matched on the process's own command line (the `--name <task>` and `--rc` the
# spawn was launched with), exactly like cmux_verify/iterm_verify do — NOT on
# tmux's #{pane_current_command}. That field reports the foreground process's
# executable name, which for claude is the interpreter (`node`, or `bash` for a
# wrapper script), never the string "claude"; matching on it reported every
# session as finished the moment it started.
#
# tmux has no equivalent of cmux's hook-fed claude_code=Idle|Running status, so
# this reports COMPLETION (the process is gone), not idleness. Those are
# different questions and the SKILL/README say so — a session sitting at a
# prompt waiting for input still counts as running here.
tmux_claude_running() {
  ps -eo command= | grep -F -- "--name $1" | grep -Fq -- "--rc"
}

tmux_verify() {
  _n="$1"; _cwd="$2"; _ref="$3"
  sleep 4
  if ps -eo command= | grep -F -- "--name $_n" | grep -Fq -- "--rc"; then
    echo "✓ session '$_n' is running detached in tmux (cwd: $_cwd)"
    echo "  attach with: tmux attach -t ${_ref#tmux:}"
  else
    echo "⚠ session '$_n' did not start — inspect it with: spawn.sh read $_n" >&2
  fi

  if sc_rc_advisory; then
    echo "ℹ remote control: no 'claude daemon' is running."
    echo "  The session runs normally in its tmux session — it is NOT headless."
    echo "  It just won't appear in the mobile/desktop app until a daemon is running."
  fi
  return 0
}
