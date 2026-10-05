# Tracks which cmux workspaces THIS skill spawned. cmux can tell you what
# workspaces exist, but not which ones are ours — without this, `list` is just
# `cmux workspace list` with extra steps.
#
# Format: <iso8601-ts>\t<name>\t<workspace_ref>\t<window_ref>\t<cwd>
# TSV, append-only: no read-modify-write, no parser dependency, greppable.
# cwd is last so embedded whitespace is safe. Names/refs cannot contain tabs.
#
# Lives outside ~/.claude on purpose: that is a git repo, and this is
# disposable per-machine state.

reg_path() {
  if [ -n "${SPAWN_REGISTRY:-}" ]; then
    printf '%s' "$SPAWN_REGISTRY"
  else
    printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/spawn-claude/spawns.tsv"
  fi
}

reg_append() {
  _rp=$(reg_path)
  mkdir -p "$(dirname "$_rp")"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" >> "$_rp"
}

reg_list() {
  _rp=$(reg_path)
  [ -f "$_rp" ] || return 0
  cat "$_rp"
}

# reg_drop <name> <ref>... — remove the rows whose NAME is <name> AND whose
# workspace ref is one of <ref>.... The name/ref PAIR must match: a ref alone
# is not enough, so a caller cleaning up one task's stale rows can never
# delete another task's row that happens to share a ref.
#
# The one read-modify-write in this file, hence the care: rows are copied to a
# temp file beside the registry and moved into place, so an interrupted or
# failed rewrite leaves the original intact rather than a truncated registry.
# Lines are copied VERBATIM (never re-printf'd from parsed fields) so a
# rewrite cannot reformat rows it is only passing through.
#
# Exit 0 on success, including when there is nothing to drop; 1 if the rewrite
# failed, in which case the registry is unchanged.
reg_drop() {
  _dname="$1"; shift
  [ $# -gt 0 ] || return 0
  _rp=$(reg_path)
  [ -f "$_rp" ] || return 0
  _tmp="$_rp.tmp.$$"
  : > "$_tmp" 2>/dev/null || return 1
  # `|| [ -n "$_line" ]` so a final row with no trailing newline is not eaten.
  while IFS= read -r _line || [ -n "$_line" ]; do
    _lname=$(printf '%s' "$_line" | cut -f2)
    _lref=$(printf '%s' "$_line" | cut -f3)
    _drop=0
    if [ "$_lname" = "$_dname" ]; then
      for _r in "$@"; do
        if [ "$_lref" = "$_r" ]; then _drop=1; break; fi
      done
    fi
    if [ "$_drop" -eq 0 ]; then
      printf '%s\n' "$_line" >> "$_tmp" || { rm -f "$_tmp"; return 1; }
    fi
  done < "$_rp"
  mv "$_tmp" "$_rp" || { rm -f "$_tmp"; return 1; }
}

# reg_drop_ref <ref> — remove every row with this workspace ref, whatever its
# name. Used when registering a new spawn: cmux reuses refs of closed
# workspaces, so an older row with the same ref is necessarily stale.
reg_drop_ref() {
  _rp=$(reg_path)
  [ -f "$_rp" ] || return 0
  _tmp="$_rp.tmp.$$"
  awk -F'\t' -v r="$1" '$3 != r' "$_rp" > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  mv "$_tmp" "$_rp" || { rm -f "$_tmp"; return 1; }
}

# reg_resolve <target> — target is a task name or a raw workspace ref.
# exit 0 = printed a ref, 2 = not found, 3 = ambiguous.
reg_resolve() {
  case "$1" in
    workspace:*|tmux:*) printf '%s' "$1"; return 0 ;;
  esac
  _matches=$(reg_list | awk -F'\t' -v n="$1" '$2 == n { print $3 }')
  [ -n "$_matches" ] || return 2
  _count=$(printf '%s\n' "$_matches" | wc -l | tr -d ' ')
  if [ "$_count" -gt 1 ]; then
    printf 'Ambiguous target "%s" — candidates:\n' "$1" >&2
    printf '%s\n' "$_matches" | sed 's/^/  /' >&2
    return 3
  fi
  printf '%s' "$_matches"
}

# reg_name_for_ref <ref> — the task name recorded for this ref, empty if none.
# Used by the tmux `wait`, which identifies the session by the --name it was
# launched with rather than by anything tmux reports.
reg_name_for_ref() {
  reg_list | awk -F'\t' -v r="$1" '$3 == r { print $2; exit }'
}
