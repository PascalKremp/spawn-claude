#!/usr/bin/env bash
# Long prompts must never be TYPED into a pty.
#
# A spawned shell receives its command as typed input. While the shell is still
# starting (pty in canonical mode) the tty line discipline truncates a line at
# MAX_CANON = 1024 bytes on macOS, so a ~1.5K prompt arrived cut off with an
# unterminated quote and never executed. The fix: the command and prompt live
# in private temp files and only a short `. <launcher>` line is typed.
. "$(dirname "$0")/harness.sh"
. "$(dirname "$0")/../scripts/lib/common.sh"
S="$(dirname "$0")/../scripts/spawn.sh"

export TMPDIR="$(mktemp -d -t launchertmp.XXXXXX)"
BIN="$(mktemp -d -t launcherbin.XXXXXX)"
OUT="$TMPDIR/args.out"
# Fake claude: records its argv NUL-separated so any content can be compared.
cat > "$BIN/claude" <<'FAKE'
#!/bin/sh
printf '%s\0' "$@" > "$CLAUDE_ARGS_OUT"
FAKE
chmod +x "$BIN/claude"
export CLAUDE_ARGS_OUT="$OUT"

# A nasty prompt: > 1024 bytes, single + double quotes, $, backticks,
# newlines (incl. trailing), umlauts, emoji and a backslash.
PROMPT="$(printf 'It'"'"'s a "test" $HOME `id` \\n Grüße äöü ß 🙂\nline2\n')"
PROMPT="$PROMPT$(python3 -c "print('verify-hvbowzyz.ssl. ' * 80)")
last line

"

check_launch() { # check_launch <label> <shell> <prompt> [extra args after prompt: model resume cont fork]
  _label="$1"; _sh="$2"; _pr="$3"; _model="${4:-}"; _res="${5:-}"; _cont="${6:-0}"; _fork="${7:-0}"
  rm -f "$OUT"
  SC_LAUNCHER=""
  sc_make_launcher "my task" "$_pr" "claude" "$_model" "$_res" "$_cont" "$_fork" || { _fail "$_label: make_launcher" ok failed; return; }
  _typed="$SC_TYPED_CMD"
  _lf="$SC_LAUNCHER"
  assert_eq "1" "$([ "${#_typed}" -lt 400 ] && echo 1 || echo 0)" "$_label: typed command is short (${#_typed} bytes)"
  [ "$(stat -f %Lp "$_lf" 2>/dev/null || stat -c %a "$_lf")" = 700 ] && _pass "$_label: launcher is 0700" || _fail "$_label: launcher is 0700" 700 "other"
  PATH="$BIN:$PATH" "$_sh" -c "$_typed"
  [ -f "$OUT" ] || { _fail "$_label: claude was executed" "args file" "missing"; return; }
  # argv: --rc --name <n> --dangerously-skip-permissions [...] <prompt-as-one-arg>
  _last=$(python3 - "$OUT" <<'PY'
import sys
a=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
sys.stdout.buffer.write(a[-1])
PY
)
  # Compare via python for byte exactness (shell strips trailing newlines).
  python3 - "$OUT" "$_pr" <<'PY' && _pass "$_label: prompt arrives byte-identical" || _fail "$_label: prompt arrives byte-identical" "identical" "differs"
import sys
a=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
want=sys.argv[2].encode()
sys.exit(0 if a[-1]==want else 1)
PY
  [ ! -e "$_lf" ] && _pass "$_label: launcher file removed after start" || _fail "$_label: launcher file removed after start" gone present
  [ -z "$(ls "$TMPDIR" | grep '^spawn-claude-')" ] && _pass "$_label: no temp files left behind" || _fail "$_label: no temp files left behind" none "$(ls "$TMPDIR")"
}

check_launch "bash long prompt" bash "$PROMPT" opus
check_launch "zsh long prompt"  zsh  "$PROMPT" opus
check_launch "sh long prompt"   sh   "$PROMPT"

# Prompt starting with '-' must not be parsed as an option.
check_launch "dash prompt" bash "-rf not an option, $(python3 -c "print('y'*1200)")"
python3 - "$OUT" <<'PY' && _pass "dash prompt is preceded by --" || _fail "dash prompt is preceded by --" "-- before prompt" "missing"
import sys
a=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
sys.exit(0 if a[-2]==b'--' else 1)
PY

# Resume / continue / fork flags survive.
check_launch "resume+fork" bash "short prompt" "" "sess-1" 0 1
assert_contains "$(tr '\0' ' ' < "$OUT")" "--resume sess-1 --fork-session" "resume + fork flags preserved"
check_launch "continue" bash "short prompt" "" "" 1 0
assert_contains "$(tr '\0' ' ' < "$OUT")" "--continue" "continue flag preserved"

# Dry-run shows the short typed line and creates no files.
out=$("$S" --dry-run --terminal tmux demo "$PROMPT" /tmp 2>&1)
assert_contains "$out" "typed:" "dry-run shows the short typed command"
assert_contains "$out" "spawn-claude-demo-" "dry-run names the launcher file"
assert_eq "" "$(ls "$TMPDIR" | grep '^spawn-claude-' || true)" "dry-run creates no launcher files"

# --- Live tmux round trip, reproducing the original bug: the shell is slow to
# start, so the typed line lands while the pty is still in canonical mode. ---
if command -v tmux >/dev/null 2>&1; then
  TMUX_TMPDIR="$(mktemp -d /tmp/lt.XXXXXX)"; export TMUX_TMPDIR
  SLOW="$BIN/slowsh"
  printf '#!/bin/sh\nsleep 1.5\nexec bash --norc --noprofile\n' > "$SLOW"; chmod +x "$SLOW"
  FAKE_HOME="$(mktemp -d -t lth.XXXXXX)"
  rm -f "$OUT"
  env HOME="$FAKE_HOME" SHELL="$SLOW" PATH="$BIN:$PATH" SPAWN_DRY_RUN=0 SPAWN_NO_VERIFY=1 \
      SPAWN_REGISTRY="$TMPDIR/reg.tsv" SPAWN_TMUX_PREFIX=lt \
      "$S" spawn --terminal tmux longp "$PROMPT" /tmp >/dev/null 2>&1
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do [ -s "$OUT" ] && break; sleep 0.5; done
  python3 - "$OUT" "$PROMPT" <<'PY' && _pass "tmux e2e: long prompt delivered intact through a slow-starting shell" || _fail "tmux e2e: long prompt delivered intact through a slow-starting shell" "identical" "missing/differs"
import sys
a=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
sys.exit(0 if a and a[-1]==sys.argv[2].encode() else 1)
PY
  tmux kill-server 2>/dev/null
  rm -rf "$TMUX_TMPDIR" "$FAKE_HOME"
fi

rm -rf "$TMPDIR" "$BIN"
report
