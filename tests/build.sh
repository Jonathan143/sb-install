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
  validate_script_artifact "$ROOT/standalone"
  SB_CMD="$ROOT/installed"
  self_install
  cmp "$ROOT/standalone" "$SB_CMD"
)
# Run existing behavior tests against the standalone artifact too.
mkdir "$ROOT/tests"
cp "$ROOT/standalone" "$ROOT/sb.sh"
cp tests/{acme,lock,core-install,core-update,script-update,transaction,builtin-acme,sni,multiplex,protocols,routing,dns,hysteria2}.sh "$ROOT/tests/"
for test in "$ROOT"/tests/*.sh; do bash "$test"; done
echo 'PASS: deterministic standalone build, self-install and bundled regressions'

# Exercise the POSIX bootstrap with a simulated Bash-less Alpine, no network/root changes.
(
  mkdir "$ROOT/minimal"
  real_bash=$(command -v bash)
  for tool in mktemp rm chmod; do ln -s "$(command -v "$tool")" "$ROOT/minimal/$tool"; done
  printf '#!/bin/sh\necho Linux\n' > "$ROOT/minimal/uname"
  printf '#!/bin/sh\necho 0\n' > "$ROOT/minimal/id"
  cat > "$ROOT/minimal/apk" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" > "$BOOTSTRAP_TEST_ROOT/apk-called"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$BOOTSTRAP_TEST_BASH" > "$BOOTSTRAP_TEST_ROOT/minimal/bash"
chmod +x "$BOOTSTRAP_TEST_ROOT/minimal/bash"
STUB
  cat > "$ROOT/minimal/curl" <<'STUB'
#!/bin/sh
for arg do target=$arg; done
"$BOOTSTRAP_TEST_CP" "$BOOTSTRAP_TEST_ROOT/standalone" "$target"
STUB
  chmod +x "$ROOT/minimal/"*
  for args in 'status' 'info 1' 'dns show' 'route show'; do
    if PATH="$ROOT/minimal" /bin/sh install.sh $args > "$ROOT/read-only-bootstrap" 2>&1; then
      echo 'FAIL: Bash-less read-only bootstrap succeeded' >&2; exit 1
    fi
    grep -q '只读查询需要先安装 Bash' "$ROOT/read-only-bootstrap"
    [[ ! -e $ROOT/apk-called && ! -e $ROOT/minimal/bash ]]
  done
  BOOTSTRAP_TEST_ROOT="$ROOT" BOOTSTRAP_TEST_BASH="$real_bash" BOOTSTRAP_TEST_CP="$(command -v cp)" \
    PATH="$ROOT/minimal" /bin/sh install.sh --version > "$ROOT/bootstrap-version"
  grep -q '^sb v' "$ROOT/bootstrap-version"
  grep -Fxq 'add --no-cache bash ca-certificates' "$ROOT/apk-called"
)
