#!/usr/bin/env bash
set -u
cd "$(dirname "$0")" || exit 1
rc=0
for t in test-*.sh; do
  [ -e "$t" ] || continue
  printf '\n=== %s ===\n' "$t"
  bash "$t" || rc=1
done
exit $rc
