---
name: spawn-claude
description: Spawn and manage background Claude Code sessions with remote control (`--rc`), a named task (`--name`), and yolo mode (`--dangerously-skip-permissions`). Inside cmux it spawns an unfocused cmux workspace (inheriting cmux status, notifications and feed); otherwise it uses a new iTerm2 window on macOS, or a detached tmux session anywhere else. On the cmux and tmux backends it can then list, read, steer, wait on, and close those sessions. Use when the user asks to "spawn claude", "open a new claude session", "launch claude in a new terminal", "kick off a background claude task", "resume/continue a session in a new window", "check on a spawned session", "send a follow-up to a background session", "wait for a background session to finish", or anything equivalent. Accepts a task name, an optional prompt to seed (or continue) the session, an optional working directory (defaults to current `$PWD`), and can resume an existing conversation by session id (`--resume`) or the most recent one (`--continue`), optionally forking it (`--fork`).
---

# spawn-claude

Launches a remote-controlled (`--rc`), yolo-mode (`--dangerously-skip-permissions`) Claude Code session — either a brand-new conversation or a **resumed/continued** one — in one of three backends, and (cmux and tmux) can subsequently list, read, steer, wait on, and close it.

## Usage

```bash
scripts/spawn.sh [spawn] [options] <name> [prompt] [cwd]
```

`spawn` is the default verb — `scripts/spawn.sh "name"` and `scripts/spawn.sh spawn "name"` are equivalent (see "Verb/name collision" below for when you must use the explicit form).

Positional:
- `<name>` — required. Used as `--name` to label the remote-controlled session. Must not contain a tab or newline (it is stored as a TSV row in the registry).
- `[prompt]` — optional. Passed as a positional argument to `claude`. For a fresh session it seeds the first turn; when resuming, it is injected as the **next** message in that conversation.
- `[cwd]` — optional. Working directory for the new session. Defaults to the current `$PWD` of the invoking shell.

Options (continue an existing conversation instead of starting fresh):
- `-r, --resume <session-id>` — resume a specific past session (`claude --resume <id>`).
- `-c, --continue` — resume the most recent conversation in `cwd` (`claude --continue`).
- `--fork` — on resume, branch into a **new** session id instead of writing back into the original (`claude --fork-session`). Use to explore an alternative without polluting the source session.
- `--cwd <dir>` — working directory (alternative to the positional `[cwd]`).
- `-m, --model <model>` — model for the spawned session (e.g. `sonnet`, `opus`, `haiku`).
- `--terminal cmux|iterm|tmux|auto` — force a backend (see Backends below). Default `auto`.
- `--dry-run` — print the resolved backend, `cwd`, and the exact command(s) that would run, then exit without touching cmux, iTerm, or `~/.claude.json`. Use to verify before launching.
- `--` — end of options; everything after is positional (use when a prompt starts with `-`).

Notes on resuming:
- `--resume` and `--continue` are mutually exclusive.
- When resuming, `<cwd>` **must** be the project directory the session belongs to — Claude scopes saved sessions per working directory. Session transcripts live under `~/.claude/projects/<slugified-cwd>/<session-id>.jsonl`.
- `<name>` is always the first positional, so to resume *with* a follow-up prompt you must pass both: `spawn.sh -r <id> "<name>" "<prompt>"`.

The script handles single-quote escaping for both the shell command and the embedded AppleScript (iTerm backend), so names/prompts containing quotes are safe.

## Backends

| | cmux | iTerm2 | tmux |
|---|---|---|---|
| Chosen when | `$CMUX_SOCKET_PATH` is set and `cmux ping` succeeds | macOS with iTerm2 installed | tmux is on `PATH` |
| Creates | an unfocused workspace in the current cmux window | a new OS window | a detached session |
| cmux hooks | inherited (status, progress, feed, notifications, auto-name, session restore) | none | none |
| Lifecycle verbs (`list`/`read`/`tell`/`key`/`wait`/`close`) | supported | not supported — nothing addressable is recorded for a window | supported |
| Needs a GUI | yes (cmux app) | yes | **no** — works headless and over SSH |

`auto` tries them in that order. Force one with `--terminal cmux|iterm|tmux|auto` or the
`SPAWN_TERMINAL` env var (the flag wins if both are given). If none is available, `auto`
fails with an explicit message rather than guessing.

**tmux is the portable backend.** It is what makes this work on Linux, in a container, or
over SSH, and it supports the same lifecycle verbs as cmux because a detached session is
addressable. Sessions are named `spawn-<task>` (`:` and `.` are replaced — tmux reads both
as address separators).

**One deliberate difference in `wait`.** On cmux, `wait` polls the hook-fed
`claude_code=Idle|Running` status, so it means *"idle, ready for input"*. tmux has no such
signal, so there `wait` means *"the claude process has exited"* — completion, not idleness.
A tmux session sitting at a prompt waiting for you still counts as running. This is
reported honestly rather than faked with a screen-scrape.

**Why the backends invoke `claude` differently.** The cmux backend emits **bare `claude`**; in a cmux workspace shell that resolves function → per-surface shim → `cmux-claude-wrapper`, which injects cmux's hook set. The iTerm and tmux backends emit the **absolute path** to the `claude` binary, because its spawned `zsh -l` sources `.zprofile` but not `.zshrc`, so PATH additions like `~/.local/bin` are missing and bare `claude` would fail with "command not found". Both are correct for their backend — this is not an inconsistency to "fix".

## Managing a running spawn (cmux and tmux)

```bash
scripts/spawn.sh list                            # live spawns: ref, name, cwd
scripts/spawn.sh read  refactor-auth --lines 40  # what is it doing? (add --scrollback to include scrollback)
scripts/spawn.sh tell  refactor-auth "also update the tests"
scripts/spawn.sh key   refactor-auth escape      # interrupt it (any cmux send-key value)
scripts/spawn.sh wait  refactor-auth --timeout 600
scripts/spawn.sh close refactor-auth
```

`<target>` is the name you passed to `spawn`, or a raw cmux ref (`workspace:94`).

- `read` shows only the **current viewport** of the Claude TUI (`cmux read-screen` under the hood) — for an idle session that's essentially just the input box, not the completed conversation. `--lines`/`--scrollback` don't recover it either; a full-screen TUI doesn't leave finished turns in scrollback the way a plain shell would. Use `read` to watch a session **while it's working** (spinner, in-progress output, current state). For the actual conversation once it's done, the transcript on disk is authoritative — see "Finding a session id to resume" below for where it lives and how to browse it. This is a property of how the TUI renders, not a bug in `read`.
- `tell` requires the message as a single, quoted argument — an unquoted multi-word message is refused with a usage error rather than silently truncated or joined, since guessing wrong would deliver mangled text to a live autonomous session.
- `wait` polls `cmux list-status --workspace <ref>` for the hook-driven `claude_code=Idle` field — the same signal that drives the cmux sidebar, not a heuristic guess at how the terminal renders its prompt. Poll interval defaults to 5s, overridable with `SPAWN_WAIT_INTERVAL` (must be a positive whole number of seconds; invalid values exit 1 rather than being silently clamped). On timeout, `wait` exits 124. **Caveat:** `wait` reports the session's *current* status, not "has finished the request I just gave it" — called immediately after `spawn` or `tell`, it can report idle in well under a second, before the seeded prompt has even started processing. Give the session a moment before calling `wait`, or call it in a loop, if you need certainty that a specific instruction actually completed.
- Every verb rejects extra positional arguments with a usage error instead of guessing what you meant (e.g. `key <target> <key> <extra>` is refused).

Spawns are tracked in `${XDG_STATE_HOME:-$HOME/.local/state}/spawn-claude/spawns.tsv` (override with `SPAWN_REGISTRY`, mainly a test seam). Liveness filtering only happens inside `list`, which drops any row whose workspace no longer exists — closing a workspace from the cmux UI simply makes it vanish from the next `list`. `read`/`tell`/`key`/`wait`/`close` do **not** re-check liveness when resolving `<target>`: they just look the name up in the registry. So a name still present in the registry but pointing at a workspace that's gone will resolve fine and only fail when the underlying `cmux` call runs — you'll see cmux's own error, not spawn-claude's "unknown target" message. `spawn.sh list` is the way to see which names are still actually live.

`list` reconciles with a **single** `cmux workspace list` call for the whole table. If that call fails, `list` prints a warning to stderr and shows **every** registered row rather than filtering — an unreachable cmux is not evidence that a session has ended, and a silently empty table would read as "nothing is running" while an autonomous session is still going.

### Reusing a task name

Names are not unique, and `close` does not remove its registry row. To keep a reused name usable, `spawn` prunes that name's rows whose workspace no longer exists just before recording the new one — so respawning under a name you've used before (as `brainc` does, always spawning as `brainc`) resolves cleanly to the newest live session.

Pruning is conservative: rows are only dropped when cmux positively reports the workspace as gone. If the `cmux workspace list` call fails, nothing is pruned. And **two genuinely live sessions sharing a name still collide** — `read`/`tell`/`key`/`wait`/`close` exit 2 with "Ambiguous target" and list the candidates, because silently picking one would steer the wrong autonomous session. Address them by ref (`workspace:94`) or spawn under distinct names.

### Verb/name collision

If the first argument to `spawn.sh` isn't a recognized verb, the whole command line is treated as `spawn <args>` (legacy positional form). This means a session **named** `list`, `read`, `tell`, `key`, `wait`, `close`, `help`, or `spawn` collides with the verb dispatcher — `spawn.sh list` spawns nothing, it runs the `list` verb. Spawn such a name via the explicit verb instead: `spawn.sh spawn list "<prompt>"`.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | usage or validation error (bad flags, missing args, invalid `--timeout`/`SPAWN_WAIT_INTERVAL`) |
| 2 | unknown or ambiguous `<target>`, or a lifecycle verb run without a reachable cmux session |
| 124 | `wait` timed out |

### The global dry-run switch

`SPAWN_DRY_RUN=1` is a genuine kill switch honoured by **every** verb — `spawn`, `list`, `read`, `tell`, `key`, `wait`, `close` — not just `spawn`. `--dry-run` on the `spawn` verb simply forces this on for that one call. Set the env var to safely inspect or script against any verb, including ones that would otherwise send a live `cmux send`/`send-key`/`workspace close`.

It **fails closed**: only an explicit `0` (or unset/empty) goes live. Any other value — `yes`, `true`, `on`, `2`, or anything malformed — is treated as dry-run. A guard someone typed slightly wrong must not become a live spawn.

## Examples

Just a named session in the current directory:
```bash
scripts/spawn.sh "refactor-auth"
```

Named session with a seed prompt:
```bash
scripts/spawn.sh "refactor-auth" "refactor the auth module"
```

Named session with seed prompt in a specific directory:
```bash
scripts/spawn.sh "refactor-auth" "refactor the auth module" ~/code/my-project
```

Force a specific backend:
```bash
scripts/spawn.sh --terminal iterm "refactor-auth" "refactor the auth module"
```

Resume a specific past session and give it a new instruction:
```bash
scripts/spawn.sh --resume b1b7542d-628b-46b5-82f4-fb56b1977a32 "social-urls" "finish the migration and run the tests"
```

Continue the most recent conversation in this directory:
```bash
scripts/spawn.sh --continue "pick-up-where-i-left-off"
```

Fork a session to explore an alternative without altering the original:
```bash
scripts/spawn.sh --resume <id> --fork "alt-approach" "try a different schema design"
```

Preview the exact command without launching:
```bash
scripts/spawn.sh --dry-run --resume <id> "name" "prompt"
```

## Finding a session id to resume

List recent transcripts for the current project (most recent first):
```bash
proj=~/.claude/projects/$(pwd | sed 's#/#-#g')
ls -t "$proj"/*.jsonl | head
```
Each filename (minus `.jsonl`) is a resumable session id. Grep the transcripts to find the right one by content.

## Remote control not attaching (session runs but isn't in the app)

Applies to **both backends** — the RC bridge is a terminal-independent daemon, not something either backend starts itself. A spawned session can run perfectly yet never appear in the mobile/desktop app. The session is not broken — remote control just didn't attach. After launch the script now prints a `✓ session … is running` line plus an advisory when the RC daemon is missing; here is the full picture. Skip this post-launch check entirely with `SPAWN_NO_VERIFY=1` (works on both backends; best-effort and never fatal either way — a missing/failed check never turns a working launch into a non-zero exit).

**How RC actually works.** The `--rc` flag makes a session *controllable*, but the bridge
to the app is a **separate long-running `claude daemon` supervisor** process. A `--rc`
spawn does **not** start that daemon. Either way the session **runs normally** — in its
own visible iTerm window, or in its own unfocused cmux workspace — it is never headless.
What a missing daemon costs is only the bridge to the **mobile/desktop app**: the session
still works and is fully usable, it just doesn't appear in the app for remote control.
Check:

```bash
pgrep -fl "claude daemon"        # is the RC supervisor up at all?
tail -30 ~/.claude/daemon.log    # why it last restarted; look for cause=upgrade
```

**The #1 cause — a mid-session CLI auto-upgrade.** When the `claude` binary updates, the
daemon logs `shutting down (cause=upgrade …)` and a new one starts with `workers=0`.
Sessions spawned across that restart do not re-register, so they vanish from the app even
though they keep running. You'll see it in `daemon.log`:

```
[supervisor] shutting down (cause=upgrade, … live_workers=1)
[supervisor] ─── daemon start ─── version=2.1.x … workers=0
```

**Recovery.** The daemon respawns on your **next interactive `claude` launch** (open a
normal `claude` session once). Once a healthy daemon is running, **re-spawn** the session
so it registers with it — a session that was already running when the daemon restarted
will not retroactively attach. Do not hand-kill the daemon to "fix" it: killing it takes
RC down for *every* running session and it does not auto-respawn from a `--rc` spawn.

**Resumed sessions keep the original session identity.** `--resume <id>` writes back into
that same conversation, so in the app it appears under the **original** session's title,
not the `--name` you passed — easy to miss when scanning for the new name. To get a
**fresh, cleanly-labelled** entry while still inheriting the resumed context, add
`--fork` (it branches into a new session id). This is the recommended way to resume a
session you also want to see/control in the app.

On the cmux backend, the post-launch advisory also notes that cmux's own hooks (status, progress, feed, notifications) are independent of the RC daemon and keep working regardless.

## Notes

- The iTerm backend requires iTerm2 installed and AppleScript automation permitted for the parent process. It is skipped automatically when unavailable (non-macOS, or iTerm not installed), falling through to tmux.
- The tmux backend requires only `tmux` on `PATH`. Attach to a spawned session with `tmux attach -t spawn-<task>`.
- `--dangerously-skip-permissions` ("yolo mode") is always on — the whole point of this skill is to fire-and-forget a background Claude session.
- The spawned session is independent: closing the invoking session does not affect it.
- Before launching, the script pre-accepts the workspace-trust dialog for the target `cwd` by setting `projects["<abs cwd>"].hasTrustDialogAccepted = true` in `~/.claude.json`. Claude has no CLI flag to bypass this prompt for interactive sessions, so we mark the folder trusted directly. This runs on every backend. Only run this skill on directories you actually trust.
- On the iTerm and tmux backends, the script resolves the absolute path of the `claude` binary in the **parent** shell (where `~/.local/bin` and similar PATH entries from `.zshrc` are available) and embeds that absolute path in the spawned script. Fallback search order: `command -v claude` → `~/.local/bin/claude` → `~/.claude/local/claude` → `/usr/local/bin/claude` → `/opt/homebrew/bin/claude`. On the cmux backend, `claude` is emitted bare on purpose (see Backends above).
