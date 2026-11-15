#!/usr/bin/env bash
# Service commands must prepare definitions and propagate activation failures.
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for scenario in start restart stop check-failure definition-failure command-failure early-exit stop-failure; do
  (
    export EVENTS="$ROOT/$scenario.events"
    SB_BIN="$ROOT/$scenario.core"
    printf '#!/bin/sh\necho check >> "$EVENTS"\nexit %s\n' \
      "$([[ $scenario == check-failure ]] && echo 1 || echo 0)" > "$SB_BIN"
    chmod +x "$SB_BIN"
    sb_args() { SB_ARGS=(); }
    write_service() {
      echo definition >> "$EVENTS"
      [[ $scenario != definition-failure ]]
    }
    sleep() { :; }
    show_log() { echo logs >> "$EVENTS"; }
    svc() {
      echo "$1" >> "$EVENTS"
      if [[ $1 == is-active ]]; then
        [[ $scenario != stop && $scenario != early-exit ]]
      else
        [[ $scenario != command-failure ]]
      fi
    }
    action=start
    case $scenario in restart) action=restart ;; stop|stop-failure) action=stop ;; esac
    svc_cmd "$action" > "$ROOT/$scenario.output" 2>&1
    result=$?
    case $scenario in
      start|restart) expected=$'check\ndefinition\n'"$action"$'\nis-active'; [[ $result == 0 ]] || fail "$scenario rejected" ;;
      stop) expected=$'stop\nis-active'; [[ $result == 0 ]] || fail 'stop rejected' ;;
      check-failure) expected=check ;;
      definition-failure) expected=$'check\ndefinition' ;;
      command-failure) expected=$'check\ndefinition\nstart\nlogs' ;;
      early-exit) expected=$'check\ndefinition\nstart\nis-active\nlogs' ;;
      stop-failure) expected=$'stop\nis-active' ;;
    esac
    [[ $(cat "$EVENTS") == "$expected" ]] || fail "$scenario operation order"
    case $scenario in
      *failure|early-exit)
        [[ $result != 0 ]] || fail "$scenario returned success"
        if grep -q '已执行:' "$ROOT/$scenario.output"; then fail "$scenario reported success"; fi ;;
    esac
  ) || exit 1
done
echo 'PASS: service preparation, command failures and runtime state checks'
