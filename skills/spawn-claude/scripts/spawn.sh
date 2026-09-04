#!/usr/bin/env bash
# Spawn a remote-controlled, yolo-mode Claude session in a new iTerm2 window
# or an unfocused cmux workspace.
#
# Usage:
#   spawn.sh [options] <name> [prompt] [cwd]
#
# Positional:
#   <name>    required, value for --name
#   [prompt]  optional, passed as positional arg to claude (a seed/first message;
#             when resuming, it is injected as the next turn in that conversation)
#   [cwd]     optional, working directory (defaults to current $PWD)
#
# Options (continue an existing conversation instead of starting fresh):
#   -r, --resume <session-id>   Resume a specific past session (claude --resume <id>)
#   -c, --continue              Resume the most recent conversation (claude --continue)
#       --fork                  On resume, branch into a NEW session id instead of
#                               writing back into the original (claude --fork-session)
#       --cwd <dir>             Working directory (alternative to the positional form)
#   -m, --model <model>         Model for the spawned session (e.g. sonnet, opus, haiku)
#       --terminal <t>          Backend: cmux, iterm, or auto (default: auto — prefers
#                               cmux when reachable, else iTerm; see SPAWN_TERMINAL below)
#       --                      End of options; remaining args are positional
#
# Notes:
#   - --resume and --continue are mutually exclusive.
#   - When resuming, <cwd> MUST be the project directory the session belongs to;
#     Claude scopes saved sessions per working directory.
#
# Env:
#   SPAWN_DRY_RUN=1    Same as --dry-run. A genuine global kill switch: every
#                      verb (spawn, list, read, tell, key, wait, close)
#                      honours it, not just spawn — --dry-run merely forces
#                      it on for one call. Fails CLOSED: only an explicit 0
#                      (or unset/empty) goes live; ANY other value —
#                      yes, true, on, 2, garbage — is treated as dry-run.
#   SPAWN_TERMINAL     Same as --terminal; the flag wins if both are given.
#   SPAWN_NO_VERIFY=1  Skip the post-launch check (process-alive on iTerm,
#                      RC-daemon health advisory on both). Best-effort, never fatal.
#   SPAWN_WAIT_INTERVAL  Poll interval in seconds for `wait` (default 5).
#                        Must be a positive whole number — 0, negative, or
#                        non-numeric values are rejected with exit 1 rather
#                        than silently clamped to the default.
#   SPAWN_REGISTRY     Override the registry file path (default
#                      ${XDG_STATE_HOME:-$HOME/.local/state}/spawn-claude/spawns.tsv).
#                      Primarily a test seam.
#
# Examples:
#   spawn.sh "refactor-auth" "refactor the auth module"
#   spawn.sh --resume 1234abcd "keep going, now add tests" /path/to/project
#   spawn.sh --continue --fork "explore an alternative approach"

set -euo pipefail

# Normalise the kill switch ONCE, before any verb reads it, so every later
# test can be a plain STRING comparison against 0/1.
#
# Fail CLOSED: anything that isn't an explicit 0 means dry-run. A malformed
# value must never be read as "go live" — see the three live-spawn incidents.
#
# Why this is not paranoia: the verbs used to test the flag with
# `[ "$dry" -eq 1 ]`. On bash 3.2 a non-integer makes `[` print "integer
# expression expected" and return 2, which an `if` reads as FALSE — so
# SPAWN_DRY_RUN=yes (or true, or on) went LIVE, and SPAWN_DRY_RUN=2 went live
# on every verb including spawn. The realistic failure is an agent writing
# SPAWN_DRY_RUN=true *as a safety guard* and getting a live close/send/send-key.
# Empty is deliberately 0, not 1: it preserves the long-standing
# "${SPAWN_DRY_RUN:-0}" meaning of an unset/blank variable.
case "${SPAWN_DRY_RUN:-0}" in
  0|"") SPAWN_DRY_RUN=0 ;;
  *)    SPAWN_DRY_RUN=1 ;;
esac

# SPAWN_NO_VERIFY had the same shape, with a smaller but still real bite: its
# two `[[ "${SPAWN_NO_VERIFY:-0}" -ne 1 ]]` tests run AFTER the workspace and
# the claude session already exist, and under `set -u` a non-integer value
# ("yes") makes that arithmetic comparison abort the script — turning a
# successful spawn into exit 1 right after "✓ spawned" printed. Everything
# past cmux_spawn is deliberately non-fatal for exactly that reason, so
# normalise this one too. It only skips a best-effort advisory, hence the
# opposite default: anything that isn't an explicit 0 means "skip".
case "${SPAWN_NO_VERIFY:-0}" in
  0|"") SPAWN_NO_VERIFY=0 ;;
  *)    SPAWN_NO_VERIFY=1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/registry.sh"
. "$SCRIPT_DIR/lib/cmux.sh"
. "$SCRIPT_DIR/lib/iterm.sh"
. "$SCRIPT_DIR/lib/tmux.sh"

# prune_stale_rows <name> — drop this name's registry rows whose cmux
# workspace no longer exists. Exit 0 on success (including "nothing to do"),
# 1 if the registry rewrite failed.
#
# Why: the registry is append-only and `close` never removes its row, and
# reg_resolve does not filter by liveness. So the SECOND spawn under a given
# name makes every later read/tell/key/wait/close <name> fail with "Ambiguous
# target", listing long-closed workspaces as candidates. That is the normal
# case, not an edge one — skills/brainc/scripts/brainc.sh spawns with the
# hardcoded name "brainc", so from its second run onward the lifecycle verbs
# are unusable by name for this feature's primary dependent.
#
# Only rows that are DEFINITELY gone are pruned. cmux_ws_exists/cmux_ws_list
# return 2 when the cmux call itself failed, and an unreachable cmux must
# never be read as "that workspace is gone" — pruning a live row would throw
# away the only handle on a running autonomous session. Two genuinely live
# sessions sharing a name therefore still collide, and that ambiguous-target
# error is the correct outcome rather than something to silently resolve.
prune_stale_rows() {
  _pname="$1"
  _wl=$(cmux_ws_list) || return 0   # call failed: nothing is definite, prune nothing
  _stale=()
  # Here-doc, not a pipe: the loop must run in THIS shell or the collected
  # refs vanish with the subshell.
  while IFS="$(printf '\t')" read -r _ts _n _ws _win _cwd; do
    [ "$_n" = "$_pname" ] || continue
    if cmux_ws_match "$_wl" "$_ws"; then continue; fi
    _stale+=("$_ws")
  done <<EOF
$(reg_list)
EOF
  [ ${#_stale[@]} -gt 0 ] || return 0
  reg_drop "$_pname" "${_stale[@]}"
}

cmd_spawn() {
resume_id=""
do_continue=0
fork=0
opt_cwd=""
model=""
dry_run="${SPAWN_DRY_RUN:-0}"
terminal="${SPAWN_TERMINAL:-auto}"
positional=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--resume)
      if [[ $# -lt 2 ]]; then echo "Error: $1 requires a session id" >&2; exit 1; fi
      resume_id="$2"; shift 2 ;;
    --resume=*)
      resume_id="${1#*=}"; shift ;;
    -c|--continue)
      do_continue=1; shift ;;
    --fork|--fork-session)
      fork=1; shift ;;
    --cwd)
      if [[ $# -lt 2 ]]; then echo "Error: --cwd requires a directory" >&2; exit 1; fi
      opt_cwd="$2"; shift 2 ;;
    --cwd=*)
      opt_cwd="${1#*=}"; shift ;;
    -m|--model)
      if [[ $# -lt 2 ]]; then echo "Error: $1 requires a model name" >&2; exit 1; fi
      model="$2"; shift 2 ;;
    --model=*)
      model="${1#*=}"; shift ;;
    --terminal)
      if [[ $# -lt 2 ]]; then echo "Error: --terminal requires cmux, iterm, or auto" >&2; exit 1; fi
      terminal="$2"; shift 2 ;;
    --terminal=*)
      terminal="${1#*=}"; shift ;;
    --dry-run)
      dry_run=1; shift ;;
    --)
      shift; while [[ $# -gt 0 ]]; do positional+=("$1"); shift; done ;;
    -*)
      echo "Error: unknown option: $1" >&2; exit 1 ;;
    *)
      positional+=("$1"); shift ;;
  esac
done

if [[ -n "$resume_id" && "$do_continue" -eq 1 ]]; then
  echo "Error: --resume and --continue are mutually exclusive" >&2
  exit 1
fi

if [[ ${#positional[@]} -lt 1 ]]; then
  echo "Usage: $0 [options] <name> [prompt] [cwd]" >&2
  echo "       options: -r/--resume <id> | -c/--continue | --fork | --cwd <dir>" >&2
  exit 1
fi

name="${positional[0]}"
# Reject tab/newline before anything downstream (either backend) can act on
# this name: reg_append's registry is TSV, so a tab shifts columns and a
# newline splits the row — either poisons every later reg_resolve lookup.
case "$name" in
  *$'\t'*|*$'\n'*)
    echo "Error: <name> must not contain a tab or newline — it would corrupt the registry: $name" >&2
    exit 1 ;;
esac
prompt="${positional[1]:-}"
cwd="${opt_cwd:-${positional[2]:-$PWD}}"

if [[ ! -d "$cwd" ]]; then
  echo "Error: directory not found: $cwd" >&2
  exit 1
fi

# Resolve to absolute path — that's what claude stores in ~/.claude.json.
cwd=$(cd "$cwd" && pwd -P)

# Backend selection: cmux (unfocused workspace) or iTerm (visible window).
# auto prefers cmux when we're running inside one (CMUX_SOCKET_PATH set and
# the cmux CLI answers a ping) and falls back to iTerm otherwise. Validated
# here, before sc_accept_trust below — an invalid --terminal must fail before
# any global state (~/.claude.json) is touched, not after.
case "$terminal" in
  auto)
    # Preference order, most integrated first: cmux (we are inside one) ->
    # iTerm (macOS, installed) -> tmux (portable, works headless and over SSH).
    if cmux_available; then
      backend=cmux
    elif iterm_available; then
      backend=iterm
    elif tmux_available; then
      backend=tmux
    else
      echo "Error: no usable terminal backend found." >&2
      echo "       Tried: cmux (not running), iTerm2 (not installed / not macOS)," >&2
      echo "       tmux (not on PATH)." >&2
      echo "       Install tmux for the portable backend, or pass --terminal explicitly." >&2
      exit 1
    fi ;;
  cmux)  backend=cmux ;;
  iterm) backend=iterm ;;
  tmux)  backend=tmux ;;
  *) echo "Error: --terminal must be cmux, iterm, tmux, or auto" >&2; exit 1 ;;
esac

# Pre-accept the workspace trust dialog for this directory so claude doesn't
# block on the "Quick safety check" prompt. State lives in ~/.claude.json
# under projects["<abs path>"].hasTrustDialogAccepted. Skipped on --dry-run so
# inspecting a command never mutates global config.
if [[ "$dry_run" != 1 ]]; then
  sc_accept_trust "$cwd"
fi

# --resume/--continue/--fork are folded into the command by sc_build_claude_cmd;
# see its header comment for the exact flag precedence. The two backends
# deliberately disagree on how the `claude` invocation itself is spelled:
if [[ "$backend" = cmux ]]; then
  # BARE `claude` on purpose. Inside a cmux workspace shell it resolves
  # function -> per-surface shim -> cmux-claude-wrapper, which injects cmux's
  # hooks (status, progress, feed, notifications, auto-name, session restore).
  # An absolute path bypasses all of that silently — the session still runs,
  # it just loses every cmux integration with no error to notice.
  claude_cmd=$(sc_build_claude_cmd "claude" "$name" "$prompt" "$model" "$resume_id" "$do_continue" "$fork")
else
  # ABSOLUTE path on purpose. The spawned login shell (`zsh -l`) sources
  # .zprofile but does NOT source .zshrc, so anything that adds to PATH from
  # .zshrc (such as ~/.local/bin) is missing — bare `claude` then fails with
  # "command not found". Pinning the absolute path here avoids that whole
  # class of "spawn ran but claude never started".
  claude_bin=$(sc_resolve_claude_bin)
  claude_cmd=$(sc_build_claude_cmd "'$(sc_shell_escape "$claude_bin")'" "$name" "$prompt" "$model" "$resume_id" "$do_continue" "$fork")
fi

# Dry-run: show exactly what would launch, then stop before touching either
# backend.
if [[ "$dry_run" = 1 ]]; then
  echo "backend: $backend"
  echo "cwd:     $cwd"
  if [[ "$backend" = cmux ]]; then
    echo "cmux:    workspace create --name '$name' --cwd '$cwd' --focus false --command <cmd>"
  elif [[ "$backend" = tmux ]]; then
    echo "tmux:    new-session -d -s '$(tmux_session_name "$name")' -c '$cwd' + send-keys <cmd>"
  fi
  echo "command: $claude_cmd"
  exit 0
fi

if [[ "$backend" = cmux ]]; then
  # `cut -c1-120` truncates each LINE, not the string, so a multi-line prompt
  # kept every one of its lines and the whole prompt became the workspace
  # description (spawn-issue-fixers passes a ~15-line heredoc, so every
  # issue-fixer workspace was labelled with its entire prompt). Collapse
  # newlines to spaces first, then truncate the single resulting line.
  desc=$(printf '%s' "${prompt:-$name}" | tr '\n' ' ' | cut -c1-120)
  ws=$(cmux_spawn "$name" "$desc" "$cwd" "$claude_cmd") || exit 1
  # `|| true` is load-bearing: by this point the workspace exists and the
  # claude command was already sent, so this best-effort window-ref scrape
  # must never be able to abort the script under set -e/pipefail. Without it,
  # a non-zero `identify` (or a SIGPIPE from `head -1` cutting `sed` off) would
  # kill the script here — orphaning a live session with no registry row and
  # no "✓ spawned" line, since the failure is silent (2>/dev/null).
  win=$(cmux_run identify 2>/dev/null | sed -n 's/.*"window_ref" : "\([^"]*\)".*/\1/p' | head -1 || true)
  # Drop this name's dead rows BEFORE appending the new one, so reusing a task
  # name doesn't make every later `tell`/`close <name>` ambiguous. See
  # prune_stale_rows. Same non-fatal rule as everything else after
  # cmux_spawn: the workspace is already live, and a registry we merely
  # failed to tidy is cosmetic next to aborting here.
  if ! prune_stale_rows "$name"; then
    echo "⚠ could not prune stale registry rows for \"$name\" — if an older spawn reused" >&2
    echo "  this name, 'tell $name'/'close $name' may report an ambiguous target; use the" >&2
    echo "  ref '$ws' directly." >&2
  fi
  # Same rule as above: by this point the workspace exists and claude is
  # already running inside it, so a failure to WRITE the registry row (full
  # disk, unwritable state dir, etc.) must not abort the script either — that
  # would be a spawn we merely failed to *log*, not a failed spawn. Warn and
  # keep going; the ref printed below still works even if `list`/`tell`/
  # `close` can no longer resolve it by name.
  if ! reg_append "$name" "$ws" "${win:-window:?}" "$cwd"; then
    echo "⚠ spawned $ws but failed to record it in the registry — 'list'/'tell $name'/'close $name' won't find it by name; use the ref '$ws' directly." >&2
  fi
  echo "✓ spawned $ws \"$name\" (cwd: $cwd)"
  echo "  read:  spawn.sh read $name"
  echo "  tell:  spawn.sh tell $name \"<text>\""
  echo "  close: spawn.sh close $name"
  # Post-launch RC-daemon health advisory (see lib/cmux.sh). Skip with
  # SPAWN_NO_VERIFY=1 — same backend-agnostic switch the iTerm path uses.
  if [[ "$SPAWN_NO_VERIFY" != 1 ]]; then
    cmux_verify "$name"
  fi
elif [[ "$backend" = tmux ]]; then
  # tmux sessions are detached and inspectable, so — unlike iTerm — they get a
  # registry row and support the same read/tell/key/wait/close verbs as cmux.
  ws=$(tmux_spawn "$name" "${prompt:-$name}" "$cwd" "$claude_cmd") || exit 1
  # Same non-fatal rule as the cmux path: the session is already live, so a
  # failure to tidy or write the registry must not abort and orphan it.
  if ! prune_stale_rows "$name"; then
    echo "⚠ could not prune stale registry rows for \"$name\" — 'tell $name'/'close $name'" >&2
    echo "  may report an ambiguous target; use the ref '$ws' directly." >&2
  fi
  if ! reg_append "$name" "$ws" "tmux:-" "$cwd"; then
    echo "⚠ spawned $ws but failed to record it in the registry — use the ref '$ws' directly." >&2
  fi
  echo "✓ spawned $ws \"$name\" (cwd: $cwd)"
  echo "  read:   spawn.sh read $name"
  echo "  tell:   spawn.sh tell $name \"<text>\""
  echo "  close:  spawn.sh close $name"
  echo "  attach: tmux attach -t ${ws#tmux:}"
  if [[ "$SPAWN_NO_VERIFY" != 1 ]]; then
    tmux_verify "$name" "$cwd" "$ws"
  fi
else
  # Launch the iTerm window (temp-script + osascript, see lib/iterm.sh).
  iterm_spawn "$cwd" "$claude_cmd"

  # Post-launch verification (process-alive + RC-daemon health advisory, see
  # lib/iterm.sh). Skip with SPAWN_NO_VERIFY=1. iterm_verify never returns
  # non-zero — a spawned session is fully usable in its iTerm window without
  # RC-app attachment, and this must not turn a working launch into a non-zero
  # exit. The guard lives here rather than inside iterm_verify because it is a
  # backend-agnostic switch, not an iTerm-specific one.
  if [[ "$SPAWN_NO_VERIFY" != 1 ]]; then
    iterm_verify "$name" "$cwd"
  fi
fi
}

require_cmux() {
  if ! cmux_available; then
    echo "Error: this command requires a cmux session." >&2
    echo "       spawn-claude's lifecycle commands are cmux-only; the iTerm" >&2
    echo "       backend cannot read or drive a spawned session." >&2
    exit 2
  fi
}

# drv_of_ref <ref> — which backend drives this session, inferred from the ref
# itself (`workspace:N` = cmux, `tmux:<session>` = tmux). Refs are recorded at
# spawn time, so a mixed registry stays correct with no schema change.
drv_of_ref() {
  case "$1" in
    tmux:*) printf 'tmux' ;;
    *)      printf 'cmux' ;;
  esac
}

# Guard for the lifecycle verbs: whichever backend owns this ref must be
# usable. iTerm-spawned sessions have no ref at all (fire-and-forget), so they
# never reach here.
require_driver() {
  case "$(drv_of_ref "$1")" in
    tmux)
      if ! tmux_available; then
        echo "Error: this session is a tmux session but tmux is not on PATH." >&2
        exit 2
      fi ;;
    *) require_cmux ;;
  esac
}

# Validates that $1 (described by $2, e.g. "--timeout" or
# "SPAWN_WAIT_INTERVAL") is a positive whole number of seconds. Bash 3.2 has
# no arithmetic regex, so this is a case-glob digit check (catches empty,
# non-numeric, and negative — a leading `-` is a non-digit character) followed
# by a >0 comparison (catches zero). Both `wait` inputs it guards drive a
# sleep/loop bound, so a bad value must fail loudly with a clear message
# naming the input and the value received — never silently clamped to a
# default (a test seam that gets its own knob wrong should be told, not
# corrected) and never left to reach a raw `sleep`/arithmetic error under
# set -e.
require_positive_int() {
  case "$1" in
    ''|*[!0-9]*)
      echo "Error: $2 must be a positive whole number of seconds (got '$1')" >&2
      exit 1 ;;
  esac
  if [ "$1" -eq 0 ]; then
    echo "Error: $2 must be a positive whole number of seconds (got '$1')" >&2
    exit 1
  fi
}

# Resolve <target> to a ref, mapping reg_resolve's exit codes to messages.
# reg_resolve: 0 = printed a ref, 2 = not found, 3 = ambiguous (candidates are
# already printed to stderr by reg_resolve itself, so we don't repeat them).
# Both failure cases exit 2 here — an ambiguous target must never silently
# resolve to one of its candidates.
resolve_or_die() {
  _rref=$(reg_resolve "$1") || {
    _rc=$?
    if [ "$_rc" -eq 2 ]; then
      echo "Error: unknown target '$1' (see: spawn.sh list)" >&2
    fi
    exit 2
  }
  printf '%s' "$_rref"
}

cmd_list() {
  dry="${SPAWN_DRY_RUN:-0}"
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      *)
        echo "Error: too many arguments: spawn.sh list" >&2
        exit 1 ;;
    esac
  done
  # Dry-run: read the registry (local file, no cmux call) and describe the
  # reconciliation call that would run, then stop — same resolve-before-
  # require_cmux ordering every other verb uses, so require_cmux never fires
  # on a dry-run. Reconciliation is ONE `cmux workspace list` for the whole
  # table (the listing is captured once and matched in-process), so name the
  # rows it would reconcile under that single call rather than implying one
  # round trip each.
  if [ "$dry" = 1 ]; then
    _n=$(reg_list | wc -l | tr -d ' ')
    if [ "$_n" -eq 0 ]; then
      echo "cmux workspace list   # nothing registered — no reconciliation calls to make"
    else
      echo "cmux workspace list   # one call, reconciles all $_n registered row(s):"
      reg_list | while IFS="$(printf '\t')" read -r ts name ws win cwd; do
        echo "                      #   $ws \"$name\""
      done
    fi
    return 0
  fi
  # Only require cmux when the registry actually holds cmux rows: a
  # tmux-only machine must still be able to run `list`.
  if reg_list | cut -f3 | grep -q '^workspace:'; then
    require_cmux
  fi
  # Capture the listing ONCE, outside the loop. Two reasons: it removes the
  # N+1 `cmux workspace list` (one per registry row), and it lets a failed
  # CALL be told apart from a workspace that is genuinely absent.
  #
  # That distinction is the whole point. This used to be a bare
  # `cmux_ws_exists "$ws" || continue`, which dropped the row on ANY non-zero
  # — including a transient cmux error and (see cmux_ws_match) a pipefail 141
  # on a successful match. `list` would then print a bare header and exit 0,
  # indistinguishable from "nothing is running". SKILL.md promises `list`
  # shows which names are still live, so that lie points the WRONG WAY: you
  # conclude an autonomous session is gone while it is still running. When the
  # call fails we therefore warn once and keep every row.
  _wl_rc=0
  if reg_list | cut -f3 | grep -q '^workspace:'; then
    _wl=$(cmux_ws_list) || _wl_rc=$?
  else
    _wl=""
  fi
  if [ "$_wl_rc" -ne 0 ]; then
    echo "⚠ could not reach cmux to reconcile — every registered row is shown below," >&2
    echo "  including any whose workspace has since been closed. Re-run when cmux answers." >&2
  fi
  printf '%-14s %-24s %s\n' "REF" "NAME" "CWD"
  reg_list | while IFS="$(printf '\t')" read -r ts name ws win cwd; do
    # Reconcile: drop rows whose workspace is DEFINITELY gone. On a failed
    # call ($_wl_rc != 0) nothing is definite, so nothing is dropped.
    # Reconcile with whichever backend owns the row. Same rule for both: a
    # row is dropped only when its session is DEFINITELY gone, never when the
    # backend merely failed to answer.
    if [ "$(drv_of_ref "$ws")" = tmux ]; then
      tmux_ws_exists "$ws"; _te=$?
      if [ "$_te" -eq 1 ]; then continue; fi
    elif [ "$_wl_rc" -eq 0 ] && ! cmux_ws_match "$_wl" "$ws"; then
      continue
    fi
    printf '%-14s %-24s %s\n' "$ws" "$name" "$cwd"
  done
}

cmd_read() {
  target=""; lines=""; scrollback=0; dry="${SPAWN_DRY_RUN:-0}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --lines) lines="$2"; shift 2 ;;
      --scrollback) scrollback=1; shift ;;
      --dry-run) dry=1; shift ;;
      *)
        if [ -n "$target" ]; then
          echo "Error: too many arguments: spawn.sh read <target> [--lines n] [--scrollback]" >&2
          exit 1
        fi
        target="$1"; shift ;;
    esac
  done
  [ -n "$target" ] || { echo "Usage: spawn.sh read <target>" >&2; exit 1; }
  ref=$(resolve_or_die "$target")
  set -- read-screen --workspace "$ref"
  if [ -n "$lines" ]; then set -- "$@" --lines "$lines"; fi
  if [ "$scrollback" -eq 1 ]; then set -- "$@" --scrollback; fi
  if [ "$dry" = 1 ]; then echo "cmux $*"; return 0; fi
  require_driver "$ref"
  if [ "$(drv_of_ref "$ref")" = tmux ]; then
    tmux_read "$ref" "$lines" "$scrollback"
  else
    cmux_run "$@"
  fi
}

cmd_tell() {
  target=""; text=""; text_set=0; dry="${SPAWN_DRY_RUN:-0}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      *)
        if [ -z "$target" ]; then
          target="$1"
        elif [ "$text_set" -eq 0 ]; then
          text="$1"; text_set=1
        else
          # An unquoted multi-word message arrives here as separate
          # positionals. Silently joining or keeping only the last one would
          # deliver mangled text to a live autonomous session — refuse and
          # make the caller quote it instead of guessing what they meant.
          echo "Error: too many arguments — quote the message: spawn.sh tell <target> \"<text>\"" >&2
          exit 1
        fi
        shift ;;
    esac
  done
  [ -n "$target" ] && [ -n "$text" ] || { echo "Usage: spawn.sh tell <target> <text>" >&2; exit 1; }
  ref=$(resolve_or_die "$target")
  if [ "$dry" = 1 ]; then
    echo "cmux send --workspace $ref -- $text"
    echo "cmux send-key --workspace $ref enter"
    return 0
  fi
  require_driver "$ref"
  if [ "$(drv_of_ref "$ref")" = tmux ]; then
    tmux_tell "$ref" "$text"
    return
  fi
  # `cmux send` does NOT append Enter. Its \n escape would be ambiguous with
  # arbitrary prompt text, so send the text and the key separately.
  cmux_run send --workspace "$ref" -- "$text"
  cmux_run send-key --workspace "$ref" enter
}

cmd_key() {
  target=""; key=""; dry="${SPAWN_DRY_RUN:-0}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      *)
        if [ -z "$target" ]; then
          target="$1"
        elif [ -z "$key" ]; then
          key="$1"
        else
          echo "Error: too many arguments: spawn.sh key <target> <key>" >&2
          exit 1
        fi
        shift ;;
    esac
  done
  [ -n "$target" ] && [ -n "$key" ] || { echo "Usage: spawn.sh key <target> <key>" >&2; exit 1; }
  ref=$(resolve_or_die "$target")
  if [ "$dry" = 1 ]; then echo "cmux send-key --workspace $ref $key"; return 0; fi
  require_driver "$ref"
  if [ "$(drv_of_ref "$ref")" = tmux ]; then
    tmux_key "$ref" "$key"
    return
  fi
  cmux_run send-key --workspace "$ref" "$key"
}

# Polls cmux's hook-driven session status — the same signal that drives the
# cmux sidebar — rather than scraping the screen for an idle-prompt marker.
# `cmux list-status --workspace <ref>` reports `claude_code=Idle|Running`
# (plus icon/color fields not needed here), fed by cmux's own Claude Code
# hooks. That makes it authoritative, not a heuristic guess at how the
# terminal renders a prompt.
#
# SPAWN_WAIT_INTERVAL overrides the poll interval (default 5s) — a testing
# seam so exit-124/timeout tests don't have to burn real wall-clock time at
# the production interval.
cmd_wait() {
  target=""; timeout=300; dry="${SPAWN_DRY_RUN:-0}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout)
        if [ $# -lt 2 ]; then echo "Error: --timeout requires seconds" >&2; exit 1; fi
        timeout="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *)
        if [ -n "$target" ]; then
          echo "Error: too many arguments: spawn.sh wait <target> [--timeout s]" >&2
          exit 1
        fi
        target="$1"; shift ;;
    esac
  done
  [ -n "$target" ] || { echo "Usage: spawn.sh wait <target> [--timeout s]" >&2; exit 1; }
  require_positive_int "$timeout" "--timeout"
  ref=$(resolve_or_die "$target")
  interval="${SPAWN_WAIT_INTERVAL:-5}"
  require_positive_int "$interval" "SPAWN_WAIT_INTERVAL"
  if [ "$dry" = 1 ]; then
    echo "poll: cmux list-status --workspace $ref every ${interval}s for claude_code=Idle, timeout ${timeout}s"
    return 0
  fi
  require_driver "$ref"

  # tmux has no equivalent of cmux's hook-fed claude_code=Idle|Running status,
  # so on that backend `wait` polls for COMPLETION — the claude process having
  # exited — which is a different question from "idle, waiting for input".
  # Reported honestly rather than faking the cmux signal with a screen-scrape.
  if [ "$(drv_of_ref "$ref")" = tmux ]; then
    # Identify the session by the --name it was launched with (see
    # tmux_claude_running); fall back to the target if the row is gone.
    _wname=$(reg_name_for_ref "$ref")
    [ -n "$_wname" ] || _wname="$target"
    elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
      if ! tmux_claude_running "$_wname"; then
        echo "✓ $target finished (claude is no longer running)"
        return 0
      fi
      sleep "$interval"
      elapsed=$((elapsed + interval))
    done
    echo "timed out after ${timeout}s waiting for $target to finish" >&2
    return 124
  fi

  elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    status=$(cmux_run list-status --workspace "$ref" 2>/dev/null || true)
    # Match claude_code=Idle as a whitespace-delimited field, not a loose
    # substring — list-status can print several status lines and more keys
    # later, and a naive `*Idle*` would also fire on e.g. a description field
    # that happens to contain the word. Absence of the claude_code key at all
    # falls through to "not idle" (the loop just keeps polling) rather than
    # being treated as idle, so a status-reporting failure can't make `wait`
    # return success spuriously.
    if printf '%s\n' "$status" | grep -Eq '(^|[[:space:]])claude_code=Idle([[:space:]]|$)'; then
      echo "✓ $target is idle"
      return 0
    fi
    sleep "$interval"
    # 10# forces base-10 interpretation: bash arithmetic otherwise reads a
    # leading-zero value (e.g. "08", "020") as octal, which either crashes
    # ("08"/"09" have no octal digit 8/9 — "value too great for base") or
    # silently under-counts (020 as octal is 16, not 20), desyncing elapsed
    # from what `sleep` actually did — `sleep`/`[ -lt ]` already treat these
    # as decimal, so this makes the arithmetic agree with them instead of
    # rejecting the input outright (require_positive_int intentionally
    # accepts leading zeros; a zero-padded number is a reasonable thing to
    # type).
    elapsed=$((elapsed + 10#$interval))
  done
  echo "⚠ timed out after ${timeout}s waiting for $target" >&2
  return 124
}

cmd_close() {
  target=""; dry="${SPAWN_DRY_RUN:-0}"
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      *)
        if [ -n "$target" ]; then
          echo "Error: too many arguments: spawn.sh close <target>" >&2
          exit 1
        fi
        target="$a" ;;
    esac
  done
  [ -n "$target" ] || { echo "Usage: spawn.sh close <target>" >&2; exit 1; }
  ref=$(resolve_or_die "$target")
  if [ "$dry" = 1 ]; then echo "cmux workspace close $ref"; return 0; fi
  require_driver "$ref"
  if [ "$(drv_of_ref "$ref")" = tmux ]; then
    tmux_close "$ref"
    return
  fi
  cmux_run workspace close "$ref"
}

usage() {
  cat <<'USAGE'
spawn.sh — spawn and manage background Claude sessions.

  spawn.sh spawn [options] <name> [prompt] [cwd]   # default verb
  spawn.sh list
  spawn.sh read  <target> [--lines n] [--scrollback]
  spawn.sh tell  <target> <text>
  spawn.sh key   <target> <key>
  spawn.sh wait  <target> [--timeout s]
  spawn.sh close <target>
  spawn.sh help

<target> is the name you passed to spawn, or a cmux ref (workspace:94).

spawn options:
  -r, --resume <id>   -c, --continue   --fork   --cwd <dir>
  -m, --model <m>     --terminal cmux|iterm|auto   --dry-run

Everything except `spawn` requires a cmux session.

Compatibility: if the first argument is not a verb, the whole command line is
treated as `spawn <args>`. A session whose NAME collides with a verb must be
spawned explicitly: spawn.sh spawn list "..."
USAGE
}

if [ $# -eq 0 ]; then usage >&2; exit 1; fi

case "$1" in
  spawn) shift; cmd_spawn "$@" ;;
  list)  shift; cmd_list  "$@" ;;
  read)  shift; cmd_read  "$@" ;;
  tell)  shift; cmd_tell  "$@" ;;
  key)   shift; cmd_key   "$@" ;;
  wait)  shift; cmd_wait  "$@" ;;
  close) shift; cmd_close "$@" ;;
  help|-h|--help) usage ;;
  # Not a verb → legacy positional form. Do NOT shift.
  *)     cmd_spawn "$@" ;;
esac
