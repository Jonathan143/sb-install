#!/usr/bin/env bash
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for scenario in success pinned check-failure service-failure restart-failure health-failure rollback-failure backup-failure snapshot-failure inactive; do
  (
    SB_DIR="$ROOT/$scenario"; CONF_DIR="$SB_DIR/conf.d"; META_DIR="$SB_DIR/meta"
    CERT_DIR="$SB_DIR/certs"; BACKUP_DIR="$SB_DIR/backup"; SB_BIN="$SB_DIR/sing-box"
    mkdir -p "$CONF_DIR" "$META_DIR" "$BACKUP_DIR"
    SB_MODE=takeover; SB_WORKDIR="$SB_DIR/work"
    printf '#!/bin/sh\necho "sing-box version 1.12.0"\n' > "$SB_BIN"; chmod 755 "$SB_BIN"
    printf 'original config\n' > "$CONF_DIR/00-base.json"
    latest_version() { echo 1.14.3; }; confirm() { return 0; }; sleep() { :; }
    install_core() {
      echo "$1" > "$SB_DIR/installed-version"
      printf '#!/bin/sh\ncase "$*" in *check*) exit %s ;; *) echo "sing-box version %s" ;; esac\n' \
        "$([[ $scenario == check-failure ]] && echo 1 || echo 0)" "$1" > "$SB_BIN"
    }
    refresh_builtin_acme_configs() { printf 'migrated config\n' > "$CONF_DIR/00-base.json"; }
    write_service() { [[ $scenario != service-failure || $(core_version) == 1.12.0 ]]; }
    svc() {
      printf '%s:%s\n' "$1" "$(core_version)" >> "$SB_DIR/events"
      case $1 in
        is-active)
          [[ $scenario != inactive ]] || return 1
          [[ $scenario != health-failure || $(core_version) == 1.12.0 ]] ;;
        restart)
          [[ $scenario != rollback-failure ]] || return 1
          [[ $scenario != restart-failure || $(core_version) == 1.12.0 ]] ;;
        *) return 0 ;;
      esac
    }
    case $scenario in
      backup-failure) cp() { return 1; } ;;
      snapshot-failure) snapshot() { return 1; } ;;
    esac
    if [[ $scenario == pinned ]]; then
      ask_choice() { echo 2; }; ask() { echo 1.14.3; }
      core_menu > "$SB_DIR/output" 2>&1; result=$?
    else update_core > "$SB_DIR/output" 2>&1; result=$?; fi
    case $scenario in
      success|pinned)
        [[ $result == 0 && $(core_version) == 1.14.3 ]] || fail "$scenario not installed"
        grep -q 'restart:1.14.3' "$SB_DIR/events" || fail 'missing restart'
        [[ $(cat "$CONF_DIR/00-base.json") == 'migrated config' ]] || fail 'missing migration' ;;
      *)
        [[ $result != 0 && $(core_version) == 1.12.0 ]] || fail "$scenario failed to restore core"
        [[ $(cat "$CONF_DIR/00-base.json") == 'original config' ]] || fail "$scenario failed to restore config"
        if grep -q '内核已更新并重启' "$SB_DIR/output"; then fail 'false update success'; fi ;;
    esac
    case $scenario in
      check-failure|service-failure|restart-failure|health-failure|rollback-failure)
        grep -q 'restart:1.12.0' "$SB_DIR/events" || fail 'old service not restarted' ;;
      backup-failure|snapshot-failure)
        [[ ! -e $SB_DIR/installed-version ]] || fail 'installed despite backup failure' ;;
      inactive) grep -q '^stop:' "$SB_DIR/events" || fail 'inactive state not restored' ;;
    esac
  ) || exit 1
done
# Service definitions are also staged: a failed write cannot truncate an old unit.
(
  printf 'old service\n' > "$ROOT/service"
  cat() { return 1; }
  if write_service_file "$ROOT/service" 755 <<< 'new service'; then fail 'service write failure accepted'; fi
  [[ $(command cat "$ROOT/service") == 'old service' ]] || fail 'service definition truncated'
) || exit 1
echo 'PASS: latest and pinned core activation, startup failures and rollback'
