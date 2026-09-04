---
description: Spawn a background Claude Code session, or manage one that is already running.
argument-hint: <task-name> [prompt] [cwd] | list | read <name> | tell <name> "<text>" | close <name>
---

Use the `spawn-claude` skill: $ARGUMENTS

With a task name, spawn a detached session for it and report the ref plus how to read,
steer and close it. With `list`/`read`/`tell`/`wait`/`close`, act on an existing spawn.

Pick the backend automatically unless the user asks for one. Remember that `wait` means
"idle" on cmux but "finished" on tmux — say which one applies.
