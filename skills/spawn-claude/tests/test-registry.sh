#!/bin/bash
. "$(dirname "$0")/harness.sh"
. "$(dirname "$0")/../scripts/lib/registry.sh"

export SPAWN_REGISTRY="$(mktemp -t spawnreg.XXXXXX)"
rm -f "$SPAWN_REGISTRY"

assert_eq "$SPAWN_REGISTRY" "$(reg_path)" "reg_path honours SPAWN_REGISTRY"

reg_append "refactor-auth" "workspace:94" "window:1" "/Users/x/proj"
reg_append "fix-migrations" "workspace:95" "window:1" "/Users/x/proj"

assert_eq "workspace:94" "$(reg_resolve refactor-auth)"   "resolve by name"
assert_eq "workspace:95" "$(reg_resolve workspace:95)"    "resolve passes through a raw ref"

assert_exit 2 "unknown target exits 2" -- reg_resolve nope

# Newest wins is NOT the rule — ambiguity is an error the caller must see.
reg_append "refactor-auth" "workspace:96" "window:1" "/Users/x/proj"
assert_exit 3 "duplicate name exits 3" -- reg_resolve refactor-auth

assert_eq "3" "$(reg_list | wc -l | tr -d ' ')" "reg_list emits every row"

# A cwd containing spaces must survive the round trip (cwd is the last field).
reg_append "spacey" "workspace:97" "window:1" "/Users/x/my proj"
assert_eq "/Users/x/my proj" "$(reg_resolve spacey >/dev/null; reg_list | awk -F'\t' '$2=="spacey"{print $5}')" "cwd with spaces survives"

rm -f "$SPAWN_REGISTRY"
report
