# Backend-agnostic helpers shared by the cmux and iTerm spawn paths.

sc_shell_escape() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

# Pre-accept the workspace trust dialog so claude doesn't block on the
# "Quick safety check" prompt. State lives in ~/.claude.json under
# projects["<abs path>"].hasTrustDialogAccepted. Required on BOTH backends —
# claude prompts regardless of which terminal it runs in.
# python3 is located via PATH rather than pinned to /usr/bin/python3: that
# path is a macOS assumption and does not exist on many Linux distributions,
# where python3 lives in /usr/bin or /usr/local/bin but is only reliably found
# through PATH.
sc_python() {
  command -v python3 2>/dev/null || command -v python 2>/dev/null || \
    { [ -x /usr/bin/python3 ] && printf '/usr/bin/python3'; }
}

sc_accept_trust() {
_py=$(sc_python)
if [ -z "$_py" ]; then
  echo "⚠ python3 not found — skipping the trust-dialog pre-accept for $1." >&2
  echo "  The spawned session may block on Claude's 'Quick safety check' prompt." >&2
  return 0
fi
"$_py" - "$1" <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
cfg = os.path.expanduser("~/.claude.json")
try:
    with open(cfg) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
projects = data.setdefault("projects", {})
entry = projects.setdefault(path, {})
entry["hasTrustDialogAccepted"] = True
# Write atomically so we never leave ~/.claude.json half-written.
fd, tmp = tempfile.mkstemp(prefix=".claude.json.", dir=os.path.expanduser("~"))
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, cfg)
PY
}

# iTerm BACKEND ONLY. The spawned `zsh -l` sources .zprofile but NOT .zshrc,
# so PATH additions from .zshrc (such as ~/.local/bin) are missing and bare
# `claude` dies with "command not found". Pinning the absolute path fixes that.
#
# The cmux backend deliberately does the OPPOSITE — see sc_build_claude_cmd
# callers in lib/cmux.sh. Do not "unify" these two; they disagree on purpose.
sc_resolve_claude_bin() {
  _bin=$(command -v claude 2>/dev/null || true)
  if [ -z "$_bin" ]; then
    for _c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
              "/usr/local/bin/claude" "/opt/homebrew/bin/claude"; do
      if [ -x "$_c" ]; then _bin="$_c"; break; fi
    done
  fi
  if [ -z "$_bin" ]; then
    echo "Error: could not locate the 'claude' binary." >&2
    echo "       Tried: \$PATH plus ~/.local/bin, ~/.claude/local, /usr/local/bin, /opt/homebrew/bin" >&2
    return 1
  fi
  printf '%s' "$_bin"
}

# sc_rc_advisory — shared by both backends. `--rc` is always folded into the
# launched command (see sc_build_claude_cmd below), but remote-control
# attachment to the mobile/desktop app rides on a separate `claude daemon`
# supervisor that a `--rc` spawn does not itself start. Exit 0 (i.e. "show the
# advisory") when that daemon is NOT running; exit 1 when it is. This is only
# the check — each backend owns its own advisory wording, since what the
# session looks like without RC attachment differs (a visible iTerm window vs.
# an unfocused cmux workspace).
sc_rc_advisory() {
  ! pgrep -f "claude daemon" >/dev/null 2>&1
}

# sc_build_claude_cmd <invocation> <name> <prompt> <model> <resume_id> <do_continue> <fork>
# <invocation> is emitted verbatim: an already-quoted absolute path for iTerm,
# or the bare word `claude` for cmux (so the cmux wrapper shim intercepts it).
sc_build_claude_cmd() {
  _inv="$1"; _name="$2"; _prompt="$3"; _model="$4"
  _resume="$5"; _continue="$6"; _fork="$7"

  _cmd="$_inv --rc --name '$(sc_shell_escape "$_name")' --dangerously-skip-permissions"
  if [ -n "$_model" ]; then
    _cmd="$_cmd --model '$(sc_shell_escape "$_model")'"
  fi
  if [ -n "$_resume" ]; then
    _cmd="$_cmd --resume '$(sc_shell_escape "$_resume")'"
  elif [ "$_continue" = "1" ]; then
    _cmd="$_cmd --continue"
  fi
  if [ "$_fork" = "1" ]; then
    _cmd="$_cmd --fork-session"
  fi
  if [ -n "$_prompt" ]; then
    _cmd="$_cmd '$(sc_shell_escape "$_prompt")'"
  fi
  printf '%s' "$_cmd"
}
