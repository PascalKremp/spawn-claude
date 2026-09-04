# spawn-claude

**Fire off background Claude Code sessions — then read, steer, and close them.**

[English](README.md) · [Deutsch](README.de.md)

---

A [Claude Code](https://claude.com/claude-code) plugin for running work in parallel. Spawn
a named session into a detached terminal, let it work, and check on it whenever you like:

```
/spawn refactor-auth "refactor the auth module and update the tests"
/spawn read refactor-auth
/spawn tell refactor-auth "also cover the expired-token case"
```

## Why

Some work doesn't need you watching it. A long refactor, a test suite being brought back
to green, three independent bugs — each can run in its own session while you do something
else.

The catch is usually that a background session becomes a black box. This one doesn't: a
spawned session is addressable, so you can see its screen, send it a follow-up, wait for
it, and shut it down.

## Install

```
/plugin marketplace add PascalKremp/spawn-claude
/plugin install spawn-claude
```

## Requirements

**tmux** (`brew install tmux` / `sudo apt install tmux`) — that's the portable path, and it
works headless and over SSH. If you're on macOS with iTerm2, or inside
[cmux](https://cmux.io), those are used instead automatically.

## Backends

|  | cmux | iTerm2 | tmux |
|---|---|---|---|
| Chosen when | you're inside cmux | macOS + iTerm2 installed | tmux on `PATH` |
| Creates | unfocused workspace | new window | detached session |
| Read / steer / wait / close | ✅ | ❌ | ✅ |
| Needs a GUI | yes | yes | **no** |

`auto` tries them in that order, and fails with a clear message if none is available
rather than guessing. Force one with `--terminal cmux|iterm|tmux|auto`.

The iTerm backend opens a visible window and is fire-and-forget — nothing addressable is
recorded, so the lifecycle verbs don't apply to it.

## Commands

```bash
spawn.sh <name> [prompt] [cwd]        # spawn (yolo mode, remote control on)
spawn.sh list                         # live spawns: ref, name, cwd
spawn.sh read  <name> --lines 40      # what is it doing? (--scrollback for more)
spawn.sh tell  <name> "<text>"        # send a follow-up instruction
spawn.sh key   <name> escape          # interrupt it
spawn.sh wait  <name> --timeout 600   # block until it's done
spawn.sh close <name>                 # shut it down
```

Options: `--resume <id>`, `--continue`, `--fork`, `--model <model>`, `--cwd <dir>`,
`--terminal <backend>`, `--dry-run`.

Sessions launch with `--dangerously-skip-permissions` — the point is to fire and forget —
so only spawn into directories you trust.

## One difference worth knowing

`wait` does not mean quite the same thing on both drivable backends:

- **cmux** polls the hook-fed `claude_code=Idle|Running` status, so `wait` means
  *"idle, ready for input"*.
- **tmux** has no such signal, so `wait` means *"the claude process has exited"* —
  completion. A tmux session sitting at a prompt waiting for you still counts as running.

That's reported honestly rather than faked with a screen-scrape.

## Notes

- Spawned sessions are independent: closing the session that launched them changes nothing.
- Before launching, the target directory is marked trusted in `~/.claude.json` so the
  session doesn't block on Claude's "Quick safety check" prompt.
- tmux sessions are named `spawn-<task>`; attach with `tmux attach -t spawn-<task>`.
- The registry of spawned sessions lives in `~/.local/state/spawn-claude/spawns.tsv`.

## Tests

```bash
bash skills/spawn-claude/tests/run-all.sh
```

278 assertions, including a live tmux spawn/read/tell/wait/close round trip against a stub
`claude` binary. The tmux round trip skips itself when tmux isn't installed.

## License

MIT
