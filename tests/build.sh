#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
bash scripts/build.sh "$ROOT/standalone"
bash scripts/build.sh "$ROOT/again"
cmp "$ROOT/standalone" "$ROOT/again"
bash sb.sh help > "$ROOT/source-help"
(cd /; bash "$ROOT/standalone" help) > "$ROOT/bundle-help"
cmp "$ROOT/source-help" "$ROOT/bundle-help"
# A source checkout installs the entire bundle, not its small loader.
(
  source ./sb.sh
  SB_CMD="$ROOT/installed"
  self_install
  cmp "$ROOT/standalone" "$SB_CMD"
)
# Run existing behavior tests against the standalone artifact too.
mkdir "$ROOT/tests"
cp "$ROOT/standalone" "$ROOT/sb.sh"
cp tests/{acme,lock,core-install,script-update,sni,multiplex}.sh "$ROOT/tests/"
for test in "$ROOT"/tests/*.sh; do bash "$test"; done
echo 'PASS: deterministic standalone build, self-install and bundled regressions'
