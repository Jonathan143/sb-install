#!/usr/bin/env bash
# Lock handling regression tests; real /proc + flock tests also run on Linux CI.
source "$(dirname "$0")/../sb.sh"
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
run_case() (
  local scenario=$1 result
  SB_LOCK="$ROOT/$scenario.lock"
  flock() {
    if [[ $1 == -w ]]; then
      [[ $scenario != timeout ]]
    else
      [[ $scenario == free || -f $ROOT/released ]]
    fi
  }
  lock_holders() { echo 4242; [[ $scenario != multiple ]] || echo 4243; }
  lock_show_process() { echo "PID: $1"; }
  lock_start_time() { if [[ -f $ROOT/changed ]]; then echo 999; else echo 123; fi; }
  lock_is_manager() { [[ $scenario != unknown ]]; }
  lock_pid_holds() { return 0; }
  lock_interactive() { [[ $scenario != noninteractive ]]; }
  confirm() {
    echo prompt >> "$ROOT/events"
    case $scenario in
      decline) return 1 ;;
      replaced) touch "$ROOT/changed" ;;
      exited) touch "$ROOT/released" ;;
    esac
    return 0
  }
  kill() {
    [[ $1 == -TERM && $2 == 4242 ]] || exit 2
    echo signal >> "$ROOT/events"
    [[ $scenario != denied ]]
  }
  rm -f "$ROOT/events" "$ROOT/changed" "$ROOT/released"
  result=0
  acquire_lock > "$ROOT/output" 2>&1 || result=$?
  case $scenario in
    free|accept|exited) [[ $result == 0 ]] || fail "$scenario failed" ;;
    *) [[ $result != 0 ]] || fail "$scenario unexpectedly succeeded" ;;
  esac
  case $scenario in
    accept|timeout|denied) grep -q signal "$ROOT/events" || fail 'missing TERM' ;;
    *) if grep -q signal "$ROOT/events" 2>/dev/null; then fail 'unexpected signal'; fi ;;
  esac
  case $scenario in
    free|unknown|multiple|noninteractive)
      [[ ! -f $ROOT/events ]] || fail 'unexpected prompt' ;;
  esac
  if [[ $scenario != free ]]; then
    grep -q 'PID: 4242' "$ROOT/output" || fail 'missing process details'
  fi
)
for scenario in free accept decline unknown multiple noninteractive replaced exited timeout denied; do
  run_case "$scenario" || exit 1
done
if [[ $(uname -s) == Linux ]] && command -v flock >/dev/null; then
  (
    SB_LOCK="$ROOT/real.lock"
    SB_CMD="$ROOT/sb.sh"
    export SB_LOCK SB_CMD
    cat > "$SB_CMD" <<'SCRIPT'
#!/usr/bin/env bash
source "$1/sb.sh"
exec 9>>"$SB_LOCK"
flock -n 9 || exit 1
: > "$2/ready"
# Builtin read avoids launching a foreground child that inherits the lock.
exec 8<>"$2/input"
while :; do read -r -t 1 line <&8 || :; done
SCRIPT
    mkfifo "$ROOT/input"
    bash "$SB_CMD" "$PROJECT" "$ROOT" &
    holder=$!
    trap 'kill "$holder" 2>/dev/null || :; wait "$holder" 2>/dev/null || :' EXIT
    for ((i=0; i<50; i++)); do [[ -f $ROOT/ready ]] && break; sleep 0.1; done
    [[ -f $ROOT/ready ]] || fail 'holder did not start'
    lock_pid_holds "$holder" || fail 'real holder not identified'
    lock_is_manager "$holder" || fail 'real manager not identified'
    [[ -n $(lock_start_time "$holder") ]] || fail 'missing process identity'
    # An independent descriptor opened on the same file must not count as a holder.
    (
      exec 9>>"$SB_LOCK"
      lock_pid_holds "$BASHPID" && exit 1
      grep -q '^lock:' "/proc/$BASHPID/fdinfo/9" && exit 1
      exit 0
    ) || fail 'unlocked descriptor mistaken for holder'
    lock_interactive() { return 0; }
    confirm() { return 0; }
    acquire_lock || fail 'real takeover failed'
    wait "$holder" 2>/dev/null || :
    # A new independent open must still be excluded after takeover.
    if flock -n "$SB_LOCK" true; then fail 'takeover lost exclusivity'; fi
  ) || exit 1
else
  echo 'SKIP: real flock integration requires Linux (runs in CI)'
fi
echo 'PASS: lock handling regression tests'
