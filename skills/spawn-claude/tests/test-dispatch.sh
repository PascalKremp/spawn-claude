#!/usr/bin/env bash
. "$(dirname "$0")/harness.sh"
S="$(dirname "$0")/../scripts/spawn.sh"

# Legacy form: no verb, first arg is the session name. brainc and
# spawn-issue-fixers depend on exactly this.
out=$("$S" --dry-run "refactor-auth" "do the thing" /tmp 2>&1)
assert_contains "$out" "--name 'refactor-auth'" "legacy positional form still spawns"

# Explicit verb form.
out=$("$S" spawn --dry-run "refactor-auth" "do the thing" /tmp 2>&1)
assert_contains "$out" "--name 'refactor-auth'" "explicit spawn verb works"

# Verb-named session requires the explicit verb (documented caveat).
out=$("$S" spawn --dry-run "list" "p" /tmp 2>&1)
assert_contains "$out" "--name 'list'" "verb-named session works via explicit spawn"

out=$("$S" help 2>&1)
assert_contains "$out" "spawn.sh spawn" "help lists the spawn verb"
assert_contains "$out" "spawn.sh close" "help lists the close verb"

assert_exit 1 "no args exits 1" -- "$S"

report
