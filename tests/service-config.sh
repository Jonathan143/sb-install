#!/usr/bin/env bash
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
SB_DIR="$ROOT/with spaces"
CONF_DIR="$SB_DIR/conf.d"
mkdir -p "$CONF_DIR"
printf '%s\n' '{"tag":"coexist-base"}' > "$SB_DIR/config.json"
printf '%s\n' '{"tag":"node-one"}' > "$CONF_DIR/01-node.json"
printf '%s\n' '{"tag":"routing"}' > "$CONF_DIR/00-egress.json"
printf '%s\n' '{"tag":"excluded-backup"}' > "$CONF_DIR/02-node.json.bak"
svc() { [[ $1 == is-active && $running == yes ]]; }
SB_ARGS=(unchanged)
SB_MODE=takeover running=yes
show_runtime_config > "$ROOT/view" || fail 'takeover view'
grep -q '服务：运行中' "$ROOT/view" || fail 'running status'
grep -q 'node-one' "$ROOT/view" || fail 'node missing'
grep -q 'routing' "$ROOT/view" || fail 'routing missing'
if grep -Eq 'coexist-base|excluded-backup' "$ROOT/view"; then fail 'unused config displayed'; fi
[[ ${SB_ARGS[*]} == unchanged ]] || fail 'view changed service arguments'
SB_MODE=coexist running=no
show_runtime_config > "$ROOT/view" || fail 'coexist view'
grep -q 'coexist-base' "$ROOT/view" || fail 'coexist base missing'
grep -q '服务：未运行' "$ROOT/view" || fail 'stopped status'
printf '{invalid' > "$CONF_DIR/00-egress.json"
if show_runtime_config > "$ROOT/view" 2>&1; then fail 'invalid JSON accepted'; fi
grep -q 'node-one' "$ROOT/view" || fail 'invalid file hid other configs'
rm "$CONF_DIR"/*.json "$SB_DIR/config.json"
show_runtime_config > "$ROOT/view" 2>&1 || fail 'empty view'
grep -q '暂无配置文件' "$ROOT/view" || fail 'empty state missing'
# Verify the menu routes the new item without starting/stopping any service.
SB_CMD="$ROOT/missing"
core_version() { echo test; }
list_ids() { :; }
pause() { :; }
show_runtime_config() { echo CONFIG_VIEW; }
main_menu <<< $'7\n0' > "$ROOT/menu" || fail 'menu config navigation'
grep -q '^CONFIG_VIEW$' "$ROOT/menu" || fail 'menu config dispatch'
grep -Eq '14 +卸载' "$ROOT/menu" || fail 'uninstall no longer last'
echo 'PASS: service configuration view and menu navigation'
