#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for script in sb.sh lib/*.sh scripts/*.sh tests/*.sh; do
  bash -n "$script"
done
# Keep expected failure scenarios and simulated prompts out of release output.
log=$(mktemp)
trap 'rm -f "$log"' EXIT
for test in acme lock core-install script-update sni multiplex protocols release build ui dns; do
  if bash "tests/$test.sh" > "$log" 2>&1; then
    printf 'PASS: %s\n' "$test"
    sed -n '/^SKIP:/p' "$log"
  else
    printf 'FAIL: %s\n' "$test" >&2
    cat "$log" >&2
    exit 1
  fi
done
