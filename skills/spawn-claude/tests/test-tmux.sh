#!/bin/bash
# tmux backend: name sanitising, ref/driver classification, key mapping, CLI
# surface, and — when tmux is actually installed — a live spawn/read/tell/close
# round trip against a stub `claude`.
. "$(dirname "$0")/harness.sh"
. "$(dirname "$0")/../scripts/lib/common.sh"
. "$(dirname "$0")/../scripts/lib/registry.sh"
. "$(dirname "$0")/../scripts/lib/tmux.sh"

S="$(dirname "$0")/../scripts/spawn.sh"

# --- session name sanitising -----------------------------------------------
# tmux reads ':' and '.' as address separators, so a name carrying either
# would produce a session nothing can address.
assert_eq "spawn-fix-auth" "$(tmux_session_name 'fix-auth')" \
  "plain name gets the spawn- prefix"
assert_eq "spawn-fix-auth" "$(tmux_session_name 'fix:auth')" \
  "colon is replaced (tmux address separator)"
assert_eq "spawn-fix-auth" "$(tmux_session_name 'fix.auth')" \
  "dot is replaced (tmux address separator)"
assert_eq "spawn-fix-auth-2" "$(tmux_session_name 'fix auth 2')" \
  "spaces are replaced"
case "$(tmux_session_name '-weird')" in
  -*) _fail "leading dash is stripped (would be read as a flag)" "no leading -" "$(tmux_session_name '-weird')" ;;
  *)  _pass "leading dash is stripped (would be read as a flag)" ;;
esac

# --- driver classification from the ref ------------------------------------
# The registry has no backend column; the ref itself says who drives it.
. "$(dirname "$0")/../scripts/lib/cmux.sh"
drv_of_ref() { case "$1" in tmux:*) printf 'tmux' ;; *) printf 'cmux' ;; esac; }
assert_eq "tmux" "$(drv_of_ref 'tmux:spawn-x')"   "tmux: ref maps to the tmux driver"
assert_eq "cmux" "$(drv_of_ref 'workspace:61')"   "workspace: ref maps to the cmux driver"

# --- registry passes tmux refs through untouched ---------------------------
export SPAWN_REGISTRY="$(mktemp -t spawnreg.XXXXXX)"; rm -f "$SPAWN_REGISTRY"
assert_eq "tmux:spawn-a" "$(reg_resolve tmux:spawn-a)" "reg_resolve passes a raw tmux ref through"
reg_append "tname" "tmux:spawn-tname" "tmux:-" "/tmp/x"
assert_eq "tmux:spawn-tname" "$(reg_resolve tname)" "reg_resolve finds a tmux row by name"
assert_eq "tname" "$(reg_name_for_ref 'tmux:spawn-tname')" "reg_name_for_ref reverses the lookup"
assert_eq "" "$(reg_name_for_ref 'tmux:nope')" "reg_name_for_ref is empty for an unknown ref"

# --- CLI surface ------------------------------------------------------------
out=$("$S" --terminal bogus x 2>&1); rc=$?
assert_eq "1" "$rc" "an invalid --terminal still exits 1"
assert_contains "$out" "tmux" "the --terminal error lists tmux as a choice"

out=$("$S" --dry-run --terminal tmux demo "a prompt" /tmp 2>&1)
assert_contains "$out" "backend: tmux"   "dry-run reports the tmux backend"
assert_contains "$out" "new-session -d"  "dry-run shows the detached new-session"
assert_contains "$out" "spawn-demo"      "dry-run shows the sanitised session name"

# --- live round trip (only where tmux is installed) ------------------------
if ! command -v tmux >/dev/null 2>&1; then
  printf '  skip tmux not installed — live round trip skipped\n'
else
  BIN=$(mktemp -d -t spawnbin.XXXXXX)
  WORK=$(mktemp -d -t spawnwork.XXXXXX)
  cat > "$BIN/claude" <<'FAKE'
#!/bin/bash
echo "STUB-CLAUDE-UP args: $*"
while true; do read -r l || sleep 1; echo "ECHO:$l"; done
FAKE
  chmod +x "$BIN/claude"
  export SPAWN_REGISTRY="$(mktemp -t spawnreg.XXXXXX)"; rm -f "$SPAWN_REGISTRY"
  export PATH="$BIN:$PATH"
  export SPAWN_NO_VERIFY=1
  NAME="sc-selftest-$$"
  SESS="spawn-$NAME"
  tmux kill-session -t "=$SESS" 2>/dev/null

  ref=$(SPAWN_DRY_RUN=0 "$S" --terminal tmux "$NAME" "hello prompt" "$WORK" 2>/dev/null \
        | sed -n 's/^✓ spawned \(tmux:[^ ]*\).*/\1/p')
  assert_eq "tmux:$SESS" "$ref" "live spawn prints the tmux ref"
  sleep 2

  screen=$(SPAWN_DRY_RUN=0 "$S" read "$NAME" 2>/dev/null)
  assert_contains "$screen" "STUB-CLAUDE-UP" "read captures the spawned pane"
  assert_contains "$screen" "--rc"           "the session was launched with --rc"
  assert_contains "$screen" "--name $NAME"   "the session carries its task name"

  SPAWN_DRY_RUN=0 "$S" tell "$NAME" "ping-from-test" >/dev/null 2>&1
  sleep 2
  screen=$(SPAWN_DRY_RUN=0 "$S" read "$NAME" 2>/dev/null)
  assert_contains "$screen" "ECHO:ping-from-test" "tell delivers text into the session"

  listing=$(SPAWN_DRY_RUN=0 "$S" list 2>/dev/null)
  assert_contains "$listing" "$NAME" "list shows a live tmux row without cmux"

  SPAWN_DRY_RUN=0 "$S" wait "$NAME" --timeout 2 >/dev/null 2>&1
  assert_eq "124" "$?" "wait times out (124) while claude is still running"

  SPAWN_DRY_RUN=0 "$S" close "$NAME" >/dev/null 2>&1
  sleep 1
  if tmux has-session -t "=$SESS" 2>/dev/null; then
    _fail "close kills the tmux session" "session gone" "still present"
  else
    _pass "close kills the tmux session"
  fi
  listing=$(SPAWN_DRY_RUN=0 "$S" list 2>/dev/null)
  case "$listing" in
    *"$NAME"*) _fail "list reconciles the closed row away" "row dropped" "$listing" ;;
    *)         _pass "list reconciles the closed row away" ;;
  esac
  pkill -f -- "--name $NAME" 2>/dev/null
  rm -rf "$BIN" "$WORK"
fi

report
