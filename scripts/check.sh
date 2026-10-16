#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for script in sb.sh scripts/*.sh tests/*.sh; do
  bash -n "$script"
done
bash tests/core-install.sh
bash tests/release.sh
