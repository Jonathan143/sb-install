#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for script in sb.sh lib/*.sh scripts/*.sh tests/*.sh; do
  bash -n "$script"
done
# Keep expected failure scenarios and simulated prompts out of release output.
log=$(mktemp)
trap 'rm -f "$log"' EXIT
for test in acme lock core-install core-update script-update transaction builtin-acme sni multiplex protocols routing release build ui dns hysteria2; do
  if bash "tests/$test.sh" > "$log" 2>&1; then
    printf 'PASS: %s\n' "$test"
    LC_ALL=C sed -n '/^SKIP:/p' "$log"
  else
    printf 'FAIL: %s\n' "$test" >&2
    cat "$log" >&2
    exit 1
  fi
done
