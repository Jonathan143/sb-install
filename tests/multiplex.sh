#!/usr/bin/env bash
# Real JSON/metadata/snapshot tests with no network or system service changes.
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
SB_DIR="$ROOT/state"
CONF_DIR="$SB_DIR/conf.d"; META_DIR="$SB_DIR/meta"; BACKUP_DIR="$SB_DIR/backup"
mkdir -p "$CONF_DIR" "$META_DIR" "$BACKUP_DIR"

fixture() {
  meta_reset
  N_ID=1; N_PROTO=$1; N_LPORT=24443; N_PPORT=34443; N_HOST=proxy.example
  N_DOMAIN=cert.example; N_SNI=sni.example
  N_UUID=00000000-0000-4000-8000-000000000001
  N_PRIV=private; N_PBK=public; N_SID=abcdef12; N_WSPATH=/ws
  N_PASS=password; N_NOTE='test node'; N_CERTMODE=manual
  N_CERT="$ROOT/cert.pem"; N_KEY="$ROOT/key.pem"
}

for proto in reality ws hy2 tuic anytls; do
  fixture "$proto"
  write_node_conf || fail "$proto legacy config"
  node_outbound > "$ROOT/client.json" || fail "$proto legacy outbound"
  jq -e '.inbounds[0] | has("multiplex") | not' "$(conf_file)" >/dev/null || fail "$proto unexpectedly enables mux"
  jq -e 'has("multiplex") | not' "$ROOT/client.json" >/dev/null || fail "$proto legacy client changed"
done

for proto in reality ws; do
  fixture "$proto"; N_MUX=1
  write_node_conf || fail "$proto mux config"
  node_outbound > "$ROOT/client.json" || fail "$proto mux outbound"
  jq -e '.inbounds[0] | .multiplex == {enabled:true,padding:true} and (.users[0] | has("flow") | not)' "$(conf_file)" >/dev/null || fail 'server mux/flow'
  jq -e '.multiplex == {enabled:true,protocol:"h2mux",max_connections:4,min_streams:4,padding:true} and (has("flow") | not)' "$ROOT/client.json" >/dev/null || fail 'client mux/flow'
  if [[ $proto == reality ]]; then
    jq -e '.inbounds[0].tls.reality.handshake.server == "sni.example"' "$(conf_file)" >/dev/null || fail 'Reality lost'
  else
    jq -e '.inbounds[0].transport == {type:"ws",path:"/ws"}' "$(conf_file)" >/dev/null || fail 'WS lost'
  fi
  meta_save
  N_MUX=0; meta_load 1 || fail 'metadata load'
  [[ $N_MUX == 1 ]] || fail 'mux not persisted'
  node_mihomo_smux > "$ROOT/smux.yaml" || fail 'mihomo output'
  for value in 'enabled: true' 'protocol: h2mux' 'max-connections: 4' 'min-streams: 4' 'only-tcp: true' 'padding: true'; do
    grep -q "$value" "$ROOT/smux.yaml" || fail "missing $value"
  done
  link=$(node_link)
  [[ $link != *flow=* && $link != *multiplex=* && $link != *smux=* ]] || fail 'invalid URI fields'
  write_nodes_txt
  grep -q 'multiplex 已开启' "$SB_DIR/nodes.txt" || fail 'missing export notice'
  (qrencode() { :; }; show_node 1) > "$ROOT/info"
  grep -q '分享链接/二维码不携带 multiplex' "$ROOT/info" || fail 'missing info notice'
  grep -q 'smux:' "$ROOT/info" || fail 'missing mihomo snippet'
  N_MUX=0
  write_node_conf || fail 'disable config'
  node_outbound > "$ROOT/client.json" || fail 'disable client'
  jq -e '.inbounds[0] | has("multiplex") | not' "$(conf_file)" >/dev/null || fail 'server mux not removed'
  jq -e 'has("multiplex") | not' "$ROOT/client.json" >/dev/null || fail 'client mux not removed'
done

# Legacy metadata must reset any state loaded from a previous mux node.
fixture reality; N_FLOW=xtls-rprx-vision; meta_save
sed '/^N_MUX=/d' "$META_DIR/1.env" > "$ROOT/legacy.env"
mv "$ROOT/legacy.env" "$META_DIR/1.env"
N_MUX=1; meta_load 1 || fail 'legacy load'
[[ $N_MUX == 0 ]] || fail 'legacy inherited mux'
write_node_conf || fail 'legacy Flow config'
jq -e '.inbounds[0].users[0].flow == "xtls-rprx-vision"' "$(conf_file)" >/dev/null || fail 'Flow lost'

# Refuse inconsistent metadata without overwriting the last valid configuration.
cp "$(conf_file)" "$ROOT/before.json"
N_MUX=1
if write_node_conf 2>/dev/null; then fail 'Flow + mux accepted'; fi
cmp "$(conf_file)" "$ROOT/before.json" || fail 'invalid state replaced config'
if node_outbound >/dev/null 2>&1; then fail 'Flow + mux outbound accepted'; fi
for proto in hy2 tuic anytls; do
  fixture "$proto"; N_MUX=1
  if write_node_conf 2>/dev/null; then fail "$proto mux accepted"; fi
  if node_outbound >/dev/null 2>&1; then fail "$proto mux outbound accepted"; fi
  if toggle_multiplex >/dev/null 2>&1; then fail "$proto toggle accepted"; fi
done

# Both conflict directions preserve state on refusal and clear the other option on approval.
(
  fixture reality; N_FLOW=xtls-rprx-vision
  confirm() { return 1; }
  if toggle_multiplex; then fail 'mux conflict refusal ignored'; fi
  [[ $N_FLOW == xtls-rprx-vision && $N_MUX == 0 ]] || fail 'refusal changed Flow'
  confirm() { return 0; }
  toggle_multiplex || fail 'enable mux'
  [[ $N_MUX == 1 && -z $N_FLOW ]] || fail 'mux did not clear Flow'
  confirm() { return 1; }
  if toggle_reality_flow; then fail 'Flow conflict refusal ignored'; fi
  [[ $N_MUX == 1 && -z $N_FLOW ]] || fail 'refusal changed mux'
  confirm() { return 0; }
  toggle_reality_flow || fail 'enable Flow'
  [[ $N_MUX == 0 && $N_FLOW == xtls-rprx-vision ]] || fail 'Flow did not clear mux'
) > "$ROOT/toggles" 2>&1 || exit 1

# Exercise the edit entry point with real metadata and real rollback snapshots.
for scenario in enable disable flow decline rollback; do
  (
    fixture reality
    case $scenario in disable|flow) N_MUX=1 ;; *) N_FLOW=xtls-rprx-vision ;; esac
    meta_save; write_node_conf || fail 'edit fixture'
    cp "$META_DIR/1.env" "$ROOT/before.env"; cp "$(conf_file)" "$ROOT/before.json"
    ask() { if [[ $scenario == flow ]]; then echo 3; else echo 8; fi; }
    confirm() { [[ $scenario != decline ]]; }
    show_node() { :; }
    if [[ $scenario == rollback ]]; then
      SB_BIN="$ROOT/reject-core"
      printf '#!/bin/sh\nexit 1\n' > "$SB_BIN"; chmod +x "$SB_BIN"
      sb_args() { SB_ARGS=(); }
    else
      apply_config() { write_nodes_txt; }
    fi
    rc=0; edit_node 1 > "$ROOT/edit-output" 2>&1 || rc=$?
    if [[ $scenario == decline || $scenario == rollback ]]; then
      [[ $rc != 0 ]] || fail "$scenario succeeded"
      cmp "$META_DIR/1.env" "$ROOT/before.env" || fail "$scenario changed metadata"
      cmp "$(conf_file)" "$ROOT/before.json" || fail "$scenario changed config"
    else
      [[ $rc == 0 ]] || fail "$scenario failed"
      meta_load 1 || fail 'edited metadata'
      case $scenario in
        enable) [[ $N_MUX == 1 && -z $N_FLOW ]] || fail 'edit did not enable mux' ;;
        disable) [[ $N_MUX == 0 && -z $N_FLOW ]] || fail 'edit did not disable mux' ;;
        flow) [[ $N_MUX == 0 && $N_FLOW == xtls-rprx-vision ]] || fail 'edit Flow conflict' ;;
      esac
    fi
  ) || exit 1
done

# Exercise new-node prompts and persistence for both supported protocols.
for proto in reality ws; do
  (
    need_core() { :; }; pick_port() { PICKED=24443; }; ask_pub_port() { echo 34443; }
    gen_uuid() { echo 00000000-0000-4000-8000-000000000001; }
    pick_sni() { PICKED=sni.example; }; detect_ip() { echo 192.0.2.1; }
    cert_flow() { N_CERTMODE=manual; N_DOMAIN=cert.example; N_CERT="$ROOT/cert.pem"; N_KEY="$ROOT/key.pem"; }
    rand_str() { echo sample; }; next_id() { echo 2; }
    SB_BIN="$ROOT/keys"
    printf '#!/bin/sh\nprintf "PrivateKey: private\\nPublicKey: public\\n"\n' > "$SB_BIN"; chmod +x "$SB_BIN"
    ask() {
      case $1 in
        请选择) [[ $proto == reality ]] && echo 1 || echo 2 ;;
        *) echo "${2:-test}" ;;
      esac
    }
    confirm() { [[ $1 == '启用 multiplex'* ]]; }
    fw_open() { :; }; apply_config() { :; }; show_node() { :; }
    add_node > "$ROOT/add-output" 2>&1 || fail "$proto add failed"
    meta_load 2 || fail 'new metadata'
    [[ $N_MUX == 1 && -z $N_FLOW ]] || fail "$proto new mux state"
    jq -e '.inbounds[0].multiplex.enabled == true' "$(conf_file)" >/dev/null || fail 'new node missing mux'
  ) || exit 1
done
echo 'PASS: multiplex regression tests'
