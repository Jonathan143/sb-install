#!/usr/bin/env bash
# Integration tests use temporary local repositories; no GitHub/network access.
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$PROJECT/scripts/release.sh"
valid_version 1.2.3 || fail 'valid version rejected'
for bad in 01.2.3 1.2 1.2.3-rc.01 1.2.3-beta 1.2.3-dev.1 1.2.3-rc.1+build '1.2.3;echo'; do
  if valid_version "$bad"; then fail 'invalid version accepted'; fi
done
version_gt 1.10.0 1.9.9 || fail 'numeric version comparison'
for version in 1.2.3-alpha.0 1.2.3-beta.1 1.2.3-rc.10; do
  valid_version "$version" || fail 'prerelease version rejected'
done
for pair in '1.2.3-beta.1 1.2.3-alpha.9' '1.2.3-rc.1 1.2.3-beta.99' '1.2.3 1.2.3-rc.9' '1.2.4-alpha.1 1.2.3' '1.2.3-beta.10 1.2.3-beta.9'; do
  read -r higher lower <<< "$pair"
  version_gt "$higher" "$lower" || fail 'prerelease comparison'
  if version_gt "$lower" "$higher" || version_gt "$higher" "$higher"; then fail 'version ordering'; fi
done
# Mock the external publishing boundary, verify exact API CLI flags without a release.
gh() { printf '%s\n' "$@" > "$ROOT/gh-args"; }
publish_release v1.2.3-beta.1 dist/sb.sh dist/SHA256SUMS
grep -Fxq -- '--prerelease' "$ROOT/gh-args" || fail 'missing prerelease flag'
grep -Fxq -- '--latest=false' "$ROOT/gh-args" || fail 'preview can replace Latest'
publish_release v1.2.3 dist/sb.sh dist/SHA256SUMS
if grep -Eq -- '^--prerelease$|^--latest=false$' "$ROOT/gh-args"; then fail 'stable release flagged as preview'; fi
new_repo() {
  rm -rf "$ROOT/remote.git" "$ROOT/work"
  git init --bare --initial-branch=main "$ROOT/remote.git" >/dev/null
  git init --initial-branch=main "$ROOT/work" >/dev/null
  cd "$ROOT/work"
  git config user.name 'Release Test'
  git config user.email 'release@example.invalid'
  mkdir scripts
  cp "$PROJECT/scripts/release.sh" scripts/release.sh
  # Production checks run separately; this isolates the release transaction.
  printf '#!/usr/bin/env bash\nexit "${CHECK_EXIT:-0}"\n' > scripts/check.sh
  printf '#!/usr/bin/env bash\nSB_VERSION="1.2.3"\n' > sb.sh
  git add .
  git commit -qm initial
  git remote add origin "$ROOT/remote.git"
  git push -q -u origin main
  BEFORE=$(git rev-parse HEAD)
}
run_release() { printf '%s\n' "$@" | bash scripts/release.sh > "$ROOT/output" 2>&1; }
assert_unchanged() {
  [[ $(git rev-parse HEAD) == "$BEFORE" ]] || fail 'unexpected commit'
  [[ -z $(git status --porcelain) ]] || fail 'unexpected file changes'
  [[ -z $(git tag) ]] || fail 'unexpected tag'
}
for spec in '1 1.2.4' '2 1.3.0' '3 2.0.0' '5 1.2.3'; do
  new_repo
  read -r choice expected <<< "$spec"
  run_release "$choice" y || { cat "$ROOT/output"; fail "release $expected"; }
  [[ $(sed -n 's/^SB_VERSION="\(.*\)"/\1/p' sb.sh) == "$expected" ]] || fail 'wrong version'
  [[ $(git rev-parse HEAD) == $(git --git-dir="$ROOT/remote.git" rev-parse main) ]] || fail 'branch not pushed'
  [[ $(git rev-parse "v$expected^{commit}") == $(git rev-parse HEAD) ]] || fail 'tag mismatch'
  git --git-dir="$ROOT/remote.git" show-ref --verify --quiet "refs/tags/v$expected" || fail 'tag not pushed'
  [[ -z $(git status --porcelain) ]] || fail 'dirty after release'
done
new_repo
run_release 6 '' y || { cat "$ROOT/output"; fail 'first preview'; }
git show-ref --verify --quiet refs/tags/v1.2.4-beta.1 || fail 'default preview tag'
run_release 6 '' y || fail 'increment preview'
git show-ref --verify --quiet refs/tags/v1.2.4-beta.2 || fail 'preview sequence'
if run_release 4 1.2.4-alpha.9 y; then fail 'preview downgrade accepted'; fi
run_release 6 v1.2.4-rc.1 y || fail 'switch to rc'
run_release 7 y || fail 'promote to stable'
[[ $(sed -n 's/^SB_VERSION="\(.*\)"/\1/p' sb.sh) == 1.2.4 ]] || fail 'promotion skipped base version'
git --git-dir="$ROOT/remote.git" show-ref --verify --quiet refs/tags/v1.2.4 || fail 'stable promotion not pushed'
if run_release 6 1.2.4-rc.2 y; then fail 'preview of released stable accepted'; fi
new_repo
# Existing remote previews must participate in version ordering.
git tag v1.3.0-rc.1
git push -q origin refs/tags/v1.3.0-rc.1
git tag -d v1.3.0-rc.1 >/dev/null
if run_release 6 1.3.0-beta.9 y; then fail 'remote newer preview ignored'; fi
[[ $(git rev-parse HEAD) == "$BEFORE" ]] || fail 'failed preview committed'
new_repo
run_release 4 v1.10.0 y || fail 'custom version'
if run_release 5 y; then fail 'duplicate tag accepted'; fi
new_repo
run_release 1 n || fail 'cancel failed'
assert_unchanged
run_release 0 || fail 'menu cancel failed'
assert_unchanged
for bad in 01.2.4 1.2.2 1.2.3-rc.1; do
  if run_release 4 "$bad" y; then fail 'invalid or lower version accepted'; fi
  assert_unchanged
done
if CHECK_EXIT=1 run_release 1 y; then fail 'failed checks ignored'; fi
assert_unchanged
printf '\n# dirty\n' >> sb.sh
if run_release 1 y; then fail 'dirty tree accepted'; fi
git restore sb.sh
assert_unchanged
git checkout -qb feature
if run_release 1 y; then fail 'wrong branch accepted'; fi
git checkout -q main
assert_unchanged
# Remote rejection must preserve local work and leave both remote refs unchanged.
printf '#!/bin/sh\nexit 1\n' > "$ROOT/remote.git/hooks/pre-receive"
chmod +x "$ROOT/remote.git/hooks/pre-receive"
if run_release 1 y; then fail 'push rejection ignored'; fi
[[ $(git --git-dir="$ROOT/remote.git" rev-parse main) == "$BEFORE" ]] || fail 'remote branch changed on rejection'
[[ -z $(git --git-dir="$ROOT/remote.git" tag) ]] || fail 'remote tag changed on rejection'
git show-ref --verify --quiet refs/tags/v1.2.4 || fail 'local recovery tag missing'
grep -q 'git push --atomic' "$ROOT/output" || fail 'missing retry instruction'
echo 'PASS: release integration tests'
