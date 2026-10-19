#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ $(ask '默认' value <<< '') == value ]] || fail default
[[ $(ask '原样' <<< 'a\b%') == 'a\b%' ]] || fail escaping
if ask 'EOF' default < /dev/null; then fail 'EOF selected default'; fi
if confirm '危险操作' y < /dev/null; then fail 'EOF confirmed'; fi
if confirm '校验' n <<< $'yesterday\nn'; then fail 'invalid confirmation accepted'; fi
confirm '校验' n <<< $'bad\nyes' || fail 'confirmation retry'
[[ $(ask_choice '菜单' 3 <<< $'9\nabc\n2') == 2 ]] || fail retry
[[ $(ask_choice '菜单' 3 <<< q) == 0 ]] || fail back
if ask_domain '域名' < /dev/null; then fail 'domain EOF'; fi
PORT_MIN=20000 PORT_MAX=60000
if pick_port tcp < /dev/null; then fail 'port EOF'; fi
# EOF must leave the menu without looping or performing a default action.
SB_CMD="$ROOT/missing"
svc() { return 1; }
core_version() { return 1; }
list_ids() { :; }
main_menu < /dev/null > "$ROOT/menu" || fail "menu EOF"
if LC_ALL=C grep -q $'\033' "$ROOT/menu"; then fail 'redirected output contains ANSI'; fi
grep -q '节点管理' "$ROOT/menu" || fail 'missing sections'
# Cancellation must occur before snapshots or persistent changes.
select_node() { SEL_ID=1; }
meta_load() { N_ID=1 N_PROTO=reality N_NOTE=test N_LPORT=1234; }
snapshot() { fail 'cancel created snapshot'; }
edit_node <<< 0
need_core() { :; }
meta_reset() { fail 'cancel initialized node'; }
add_node <<< 0
echo 'PASS: terminal input, EOF, menu validation and cancellation'
