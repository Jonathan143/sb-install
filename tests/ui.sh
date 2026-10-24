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
# Simulate a previously colored terminal even when CI itself has no TTY.
RED=$'\033[31m'; GREEN=$'\033[32m'; CYAN=$'\033[36m'; PLAIN=$'\033[0m'
main_menu < /dev/null > "$ROOT/menu" || fail "menu EOF"
if LC_ALL=C grep -q $'\033' "$ROOT/menu"; then fail 'redirected output contains ANSI'; fi
grep -q '节点管理' "$ROOT/menu" || fail 'missing sections'
# Exercise the main menu: a back action must not consume an extra Enter.
# Stub pause because redirected CI input is not a terminal.
(
  META_DIR="$ROOT/nodes" CERT_DIR="$ROOT/certs"
  mkdir -p "$META_DIR"
  touch "$META_DIR/1.env"
  list_ids() { echo 1; }
  list_nodes() { :; }
  need_core() { :; }
  meta_load() { N_ID=1 N_PROTO=reality N_NOTE=test N_LPORT=1234; }
  snapshot() { fail 'back created snapshot'; }
  pause() { echo PAUSED >> "$ROOT/pauses"; }
  show_node() { echo SHOWN >> "$ROOT/shown"; }
  for choice in 1 2 3 4 8 9 10 11; do
    for back in 0 q Q; do
      main_menu <<< "$choice
$back
0" > /dev/null || fail "menu navigation"
    done
  done
  main_menu <<< $'3\n1\n0\n0' > /dev/null || fail "menu navigation"
  [[ ! -e $ROOT/pauses ]] || fail 'back paused'
  # A successful selection after returning must still pause to show its output.
  main_menu <<< $'2\n0\n2\n1\n0' > /dev/null || fail "menu navigation"
  [[ $(wc -l < "$ROOT/pauses") -eq 1 && -s $ROOT/shown ]] || fail 'result did not pause'
  main_menu <<< $'2\n999\n0' > /dev/null || fail "menu navigation"
  [[ $(wc -l < "$ROOT/pauses") -eq 2 ]] || fail 'error did not pause'
)
# Cancellation must occur before snapshots or persistent changes.
select_node() { SEL_ID=1; }
meta_load() { N_ID=1 N_PROTO=reality N_NOTE=test N_LPORT=1234; }
snapshot() { fail 'cancel created snapshot'; }
edit_node <<< 0
need_core() { :; }
meta_reset() { fail 'cancel initialized node'; }
add_node <<< 0
echo 'PASS: terminal input, EOF, menu validation and cancellation'

ui_title 'redirected title' > "$ROOT/title"
info 'redirected info' 2> "$ROOT/info"
if LC_ALL=C grep -q $'\033' "$ROOT/title" "$ROOT/info"; then fail 'render retained stale colors'; fi
NO_COLOR=1
ui_colors 1
[[ -z $RED$GREEN$CYAN$PLAIN ]] || fail 'NO_COLOR ignored'
