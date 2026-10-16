#!/usr/bin/env bash
# Exercise replacement in a subprocess so returning to the old menu is detected.
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cat > "$ROOT/download" <<'SCRIPT'
#!/usr/bin/env bash
SB_VERSION="9.9.9"
if { : >&9; } 2>/dev/null; then exit 42; fi
echo new-script
SCRIPT
run_case() (
  local scenario=$1 result=0
  SCRIPT_URL=https://example.invalid/sb.sh
  SB_CMD="$ROOT/$scenario"
  curl() { cp "$ROOT/download" "$4"; }
  save_conf() { :; }
  confirm() { [[ $scenario != cancel ]]; }
  if [[ $scenario == install-failure ]]; then install() { return 1; }; fi
  if [[ $scenario == move-failure ]]; then mv() { return 1; }; fi
  exec 9>"$ROOT/lock"
  if [[ $scenario == cli ]]; then
    update_script || result=$?
  else
    update_script restart || result=$?
  fi
  echo "old-script:$result"
)
for scenario in restart cli cancel install-failure move-failure eof; do
  if [[ $scenario == eof ]]; then
    run_case "$scenario" < /dev/null > "$ROOT/output" 2>&1
  else
    run_case "$scenario" <<< '' > "$ROOT/output" 2>&1
  fi
  [[ $? == 0 ]] || fail "$scenario failed"
  case $scenario in
    restart)
      grep -q '^new-script$' "$ROOT/output" || fail 'new script did not run or lock was inherited'
      if grep -q old-script "$ROOT/output"; then fail 'returned to old script'; fi ;;
    eof)
      if grep -Eq 'old-script|new-script' "$ROOT/output"; then fail 'EOF did not exit'; fi ;;
    cli|cancel) grep -q '^old-script:0$' "$ROOT/output" || fail "$scenario did not return" ;;
    *) grep -q '^old-script:1$' "$ROOT/output" || fail 'installation failure ignored' ;;
  esac
done
echo 'PASS: script update regression tests'
