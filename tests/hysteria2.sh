#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
SB_DIR="$ROOT"; META_DIR="$ROOT/meta"; CONF_DIR="$ROOT/conf.d"; BACKUP_DIR="$ROOT/backup"
mkdir -p "$META_DIR" "$CONF_DIR" "$BACKUP_DIR"
meta_reset
N_ID=1 N_PROTO=hy2 N_LPORT=24443 N_PPORT=34443 N_HOST=2001:db8::1
N_PASS='pass:/?#' N_OBFS='obfs&?' N_DOMAIN=example.com N_NOTE='hy2 "test"' N_INSECURE=1
# Keep server TLS independent from actual certificate files.
tls_server_json() { echo '{"enabled":true}'; }
write_node_conf
cp "$(conf_file)" "$ROOT/original.json"
node_outbound | jq -e '.server_port == 34443 and (has("server_ports")|not) and (has("hop_interval")|not)' >/dev/null || fail 'legacy outbound'
meta_save
# Old metadata must reset any state left by a previous hopping node.
sed '/^N_HOP_/d' "$META_DIR/1.env" > "$META_DIR/2.env"
N_HOP_PORTS=20000-30000 N_HOP_INTERVAL=15
meta_load 2
[[ -z $N_HOP_PORTS && -z $N_HOP_INTERVAL ]] || fail 'legacy metadata inherited hopping'
meta_load 1
for bad in 0-100 1-65536 2-1 80-80 080-90 1:200 '100-200;id' 10000000000-20000000000; do
  if hy2_hop_range_valid "$bad"; then fail "range accepted: $bad"; fi
done
pick_hy2_hop <<< $'bad\n20000-30000\n0\n15'
[[ $N_HOP_PORTS == 20000-30000 && $N_HOP_INTERVAL == 15 ]] || fail input
meta_save; meta_reset; meta_load 1
[[ $N_HOP_PORTS == 20000-30000 && $N_HOP_INTERVAL == 15 ]] || fail persistence
node_outbound | jq -e '.server_ports == ["20000:30000"] and .hop_interval == "15s" and
 (has("server_port")|not) and .password == "pass:/?#" and .obfs.password == "obfs&?"' >/dev/null || fail 'hopping outbound'
link=$(node_link)
[[ $link == 'hysteria2://pass%3A%2F%3F%23@[2001:db8::1]:20000-30000?'* ]] || fail URI
[[ $link == *'obfs-password=obfs%26%3F'* ]] || fail 'obfs URI escaping'
node_mihomo_hy2 > "$ROOT/mihomo"
grep -Fq 'ports: "20000-30000"' "$ROOT/mihomo" || fail 'Mihomo range'
grep -q 'hop-interval: 15' "$ROOT/mihomo" || fail 'Mihomo interval'
write_nodes_txt
meta_load 1
grep -q '间隔 15 秒' "$SB_DIR/nodes.txt" || fail 'export note'
(qrencode() { :; }; show_node 1) > "$ROOT/info"
grep -q '20000-30000（间隔 15 秒）' "$ROOT/info" || fail 'node details'
write_node_conf
cmp "$(conf_file)" "$ROOT/original.json" || fail 'hopping changed inbound'
if pick_hy2_hop <<< $'21000-31000\nq'; then fail 'cancellation accepted'; fi
[[ $N_HOP_PORTS == 20000-30000 && $N_HOP_INTERVAL == 15 ]] || fail 'cancel changed fields'
if pick_hy2_hop < /dev/null; then fail 'EOF accepted'; fi
for bad in 0 4 86401 05 '1s' '1;id'; do
  N_HOP_INTERVAL=$bad
  if node_outbound >/dev/null 2>&1; then fail 'invalid interval exported'; fi
done
N_HOP_INTERVAL=15
pick_hy2_hop <<< 0
node_outbound | jq -e '.server_port == 34443 and (has("server_ports")|not) and (has("hop_interval")|not)' >/dev/null || fail disable
[[ $(node_link) == *']:34443?'* ]] || fail 'disabled URI'
# Editing applies metadata, and a failed apply restores the saved settings.
meta_save
select_node() { SEL_ID=1; }
show_node() { :; }
apply_config() { return 0; }
edit_node 1 <<< $'9\n20000-30000\n20'
meta_load 1
[[ $N_HOP_PORTS == 20000-30000 && $N_HOP_INTERVAL == 20 ]] || fail 'edit did not persist'
apply_config() { restore_snapshot; return 1; }
if edit_node 1 <<< $'9\n22000-32000\n30'; then fail 'failed apply succeeded'; fi
meta_load 1
[[ $N_HOP_PORTS == 20000-30000 && $N_HOP_INTERVAL == 20 ]] || fail rollback
printf 'PASS: Hysteria2 hopping exports, metadata, validation, cancellation and edit rollback\n'
