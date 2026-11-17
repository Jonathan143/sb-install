#!/usr/bin/env bash
# Protocol exports, node lifecycle and dual-network behavior; no system changes.
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
SB_DIR="$ROOT/state"; CONF_DIR="$SB_DIR/conf.d"; META_DIR="$SB_DIR/meta"
BACKUP_DIR="$SB_DIR/backup"
mkdir -p "$CONF_DIR" "$META_DIR" "$BACKUP_DIR"
fixture() {
  meta_reset
  N_ID=1; N_PROTO=$1; N_LPORT=24443; N_PPORT=34443; N_HOST=2001:db8::1
  N_SNI=www.example.com; N_PRIV=private; N_PBK=public; N_SID=0123456789abcdef
  N_PASS='password:/+?#"'; N_NOTE=$'node "quoted"\nnext'
}

fixture anytls-reality
write_node_conf || fail 'AnyTLS Reality inbound'
node_outbound > "$ROOT/client.json" || fail 'AnyTLS Reality outbound'
jq -e '.inbounds[0] | .type == "anytls" and .users[0].password == "password:/+?#\"" and
  .tls.reality.handshake == {server:"www.example.com",server_port:443} and
  .tls.reality.short_id == ["0123456789abcdef"] and
  (has("multiplex") | not) and (.users[0] | has("flow") | not) and
  (.tls | has("certificate_path") | not)' "$(conf_file)" >/dev/null || fail 'AnyTLS Reality fields'
jq -e '.tls.reality.public_key == "public" and .tls.utls.fingerprint == "chrome" and
  .server == "2001:db8::1" and .server_port == 34443 and (has("flow") | not)' "$ROOT/client.json" >/dev/null || fail 'Reality outbound fields'
if node_link > "$ROOT/link"; then fail 'unverified Reality URI emitted'; fi
[[ ! -s $ROOT/link ]] || fail 'unexpected URI'
meta_save; write_nodes_txt
grep -q 'Mihomo 不支持' "$SB_DIR/nodes.txt" || fail 'missing export limitation'
(qrencode() { fail 'Reality QR emitted'; }; show_node 1) > "$ROOT/info" || fail 'Reality info'
grep -q 'Clash Verge Rev / Mihomo 不支持' "$ROOT/info" || fail 'missing compatibility notice'
if grep -q 'Loon\|smux:\|Flow:' "$ROOT/info"; then fail 'irrelevant Reality output'; fi

for method in chacha20-ietf-poly1305 aes-128-gcm aes-256-gcm 2022-blake3-aes-128-gcm; do
  fixture ss; N_METHOD=$method
  generate_ss_password || fail 'generate password'
  if [[ $method != 2022-* ]]; then N_PASS='password:/+?#"'; fi
  write_node_conf || fail "$method inbound"
  node_outbound > "$ROOT/client.json" || fail "$method outbound"
  jq -e --arg method "$method" --arg pw "$N_PASS" '.inbounds[0] |
    .type == "shadowsocks" and .method == $method and .password == $pw and
    (has("network") | not) and (has("tls") | not)' "$(conf_file)" >/dev/null || fail 'SS inbound fields'
  jq -e --arg method "$method" --arg pw "$N_PASS" '.type == "shadowsocks" and
    .method == $method and .password == $pw and .server_port == 34443' "$ROOT/client.json" >/dev/null || fail 'SS outbound fields'
  link=$(node_link) || fail 'SS link'
  [[ $link == ss://*'@[2001:db8::1]:34443#node%20%22quoted%22%0Anext' ]] || fail 'URI address/name encoding'
  if [[ $method == 2022-* ]]; then
    [[ $N_PASS =~ ^[A-Za-z0-9+/]{21}[AQgw]==$ ]] || fail 'SS2022 key length'
    [[ $link == "ss://$method:$(urlenc "$N_PASS")@"* ]] || fail 'SIP002 AEAD-2022 encoding'
  else
    encoded=$(printf '%s' "$method:$N_PASS" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
    [[ $link == "ss://$encoded@"* ]] || fail 'SIP002 AEAD encoding'
  fi
  node_mihomo_ss > "$ROOT/mihomo.yaml" || fail 'Mihomo export'
  grep -Fq 'name: "node \"quoted\"\nnext"' "$ROOT/mihomo.yaml" || fail 'YAML escaping'
  grep -q 'udp: true' "$ROOT/mihomo.yaml" || fail 'Mihomo UDP'
  meta_save; N_METHOD=wrong; meta_load 1
  [[ $N_METHOD == "$method" ]] || fail 'method persistence'
  (qrencode() { :; }; show_node 1) > "$ROOT/info" || fail 'SS info'
  grep -q 'Mihomo 配置' "$ROOT/info" || fail 'missing SS YAML'
  if grep -q 'Loon' "$ROOT/info"; then fail 'unrequested Loon output'; fi
done
cp "$(conf_file)" "$ROOT/before.json"
N_PASS=not-a-key
if write_node_conf 2>/dev/null; then fail 'bad SS2022 key accepted'; fi
cmp "$(conf_file)" "$ROOT/before.json" || fail 'invalid key overwrote config'
N_METHOD=none
if node_outbound >/dev/null 2>&1; then fail 'unsupported SS method accepted'; fi
for proto in anytls-reality ss; do
  fixture "$proto"; N_MUX=1
  if write_node_conf 2>/dev/null; then fail "$proto sing-mux accepted"; fi
done

# A busy UDP socket alone must prevent choosing an SS port; status needs both.
(
  ss() { [[ $2 != -lun ]] || echo 'UNCONN 0 0 0.0.0.0:24443 0.0.0.0:*'; }
  port_in_use 24443 both || fail 'UDP conflict missed'
  if port_listening 24443 both; then fail 'partial listener shown as running'; fi
  ss() { echo 'STATE 0 0 0.0.0.0:24443 0.0.0.0:*'; }
  port_listening 24443 both || fail 'dual listener not detected'
) || exit 1

# Preserve pre-existing rules, own only additions, and retain failed cleanup records.
(
  SB_DIR="$ROOT/firewall-state"; mkdir -p "$SB_DIR"
  NODE_FW_ADDED=(); FW_UNINSTALL=1
  ufw() {
    case $1 in
      status)
        [[ ${query_fail:-0} == 0 ]] || return 1
        echo 'Status: active'
        echo '24443/tcp ALLOW IN 192.0.2.1'
        echo '24443/udp (v6) ALLOW IN 2001:db8::1'
        [[ ! -e $SB_DIR/tcp ]] || echo '24443/tcp ALLOW Anywhere'
        [[ ! -e $SB_DIR/udp ]] || echo '24443/udp ALLOW Anywhere'
        return 0 ;;
      allow) touch "$SB_DIR/${2##*/}"; [[ ${add_fail:-0} == 0 || $2 != */udp ]] ;;
      delete) [[ ${delete_fail:-0} == 0 ]] || return 1; rm -f "$SB_DIR/${3##*/}" ;;
      *) return 1 ;;
    esac
  }
  touch "$SB_DIR/tcp"
  fw_open 24443 both || fail 'dual protocol opening'
  [[ $(cat "$SB_DIR/firewall.rules") == 'ufw|runtime|-|24443|udp' ]] || fail 'claimed existing rule'
  delete_fail=1
  if fw_close 24443 both; then fail 'cleanup failure hidden'; fi
  [[ -s $SB_DIR/firewall.rules ]] || fail 'lost cleanup record'
  delete_fail=0
  fw_close 24443 both || fail 'cleanup retry'
  [[ -e $SB_DIR/tcp && ! -e $SB_DIR/udp && ! -s $SB_DIR/firewall.rules ]] || fail 'removed existing rule'
  query_fail=1
  if fw_open 24443 tcp; then fail 'query failure hidden'; fi
  query_fail=0; add_fail=1
  svc() { return 1; }
  if node_change fw_open 24443 both; then fail 'partial firewall failure accepted'; fi
  [[ -e $SB_DIR/tcp && ! -e $SB_DIR/udp && ! -s $SB_DIR/firewall.rules ]] || fail 'partial failure rollback removed existing rule'
  add_fail=0
  fw_open 24443 both || fail 'reopen rule'
  FW_UNINSTALL=0
  fw_port_referenced() { return 0; }
  fw_close 24443 udp || fail 'shared reference check'
  [[ -e $SB_DIR/udp ]] || fail 'shared rule removed'
) || exit 1

# firewalld scopes are independent; never reload or claim an existing permanent rule.
(
  SB_DIR="$ROOT/firewalld-state"; mkdir -p "$SB_DIR"
  NODE_FW_ADDED=()
  firewall-cmd() {
    local scope=runtime arg
    for arg in "$@"; do [[ $arg != --permanent ]] || scope=permanent; done
    case ${*: -1} in
      --query-port=*) [[ -f $SB_DIR/$scope ]] ;;
      --add-port=*) touch "$SB_DIR/$scope" ;;
      --remove-port=*) rm -f "$SB_DIR/$scope" ;;
      *) fail 'unexpected firewalld operation' ;;
    esac
  }
  touch "$SB_DIR/permanent"
  fw_ensure_rule firewalld permanent public 24443 tcp || fail 'existing permanent rule'
  fw_ensure_rule firewalld runtime public 24443 tcp || fail 'runtime rule'
  [[ ${#NODE_FW_ADDED[@]} == 1 ]] || fail 'claimed permanent scope'
  fw_remove_entry "${NODE_FW_ADDED[0]}" || fail 'runtime cleanup'
  [[ -f $SB_DIR/permanent && ! -f $SB_DIR/runtime ]] || fail 'scope cleanup'
) || exit 1

# iptables inspection failures must not be interpreted as missing rules.
(
  SB_DIR="$ROOT/iptables-state"; mkdir -p "$SB_DIR"; NODE_FW_ADDED=()
  iptables() {
    case $1 in
      -S) [[ ${query_fail:-0} == 0 ]] ;;
      -C) [[ -f $SB_DIR/rule ]] ;;
      -I) touch "$SB_DIR/rule" ;;
      -D) rm -f "$SB_DIR/rule" ;;
    esac
  }
  fw_ensure_rule iptables runtime - 24443 tcp || fail 'iptables add'
  fw_remove_entry "${NODE_FW_ADDED[0]}" || fail 'iptables cleanup'
  query_fail=1
  if fw_ensure_rule iptables runtime - 24443 tcp; then fail 'iptables query failure accepted'; fi
) || exit 1

# Actual add/edit/delete entry points, with system effects stubbed.
for proto in anytls-reality ss; do
  (
    # Reusing an ID gap must still display the newly added node after export.
    fixture ss; N_ID=3; N_METHOD=aes-128-gcm; meta_save; write_node_conf
    need_core() { :; }; core_version() { echo 1.12.0; }
    pick_port() { PICKED=24443; }; ask_pub_port() { echo 34443; }
    pick_sni() { PICKED=www.example.com; }; detect_ip() { echo 192.0.2.1; }
    generate_reality_keys() { N_PRIV=private; N_PBK=public; N_SID=abcdef12; }
    cert_flow() { fail 'new protocols requested a certificate'; }
    next_id() { echo 2; }
    ask() {
      case $1 in
        请选择) [[ $proto == ss ]] && echo 7 || echo 6 ;;
        选择加密方式) echo 4 ;;
        *) echo "${2:-test}" ;;
      esac
    }
    confirm() { fail 'unexpected Flow/mux prompt'; }
    fw_open() { :; }; fw_close() { :; }; apply_config() { write_nodes_txt; }
    show_node() { echo "$1" > "$ROOT/shown"; }
    add_node > "$ROOT/add" 2>&1 || fail "$proto add"
    [[ $(cat "$ROOT/shown") == 2 ]] || fail 'add displayed another node'
    meta_load 2 || fail 'new metadata'
    [[ $N_PROTO == "$proto" && -z $N_CERTMODE && -z $N_FLOW && $N_MUX == 0 ]] || fail 'new node state'
    if [[ $proto == ss ]]; then validate_ss || fail 'new SS key'; fi
    ask() { echo 4; }
    edit_node 2 > "$ROOT/edit" 2>&1 || fail 'regenerate credentials'
    ask() { echo 2; }
    pick_ss_method() { N_METHOD=aes-128-gcm; }
    edit_node 2 > "$ROOT/edit" 2>&1 || fail 'edit SNI/method'
    meta_load 2
    [[ $proto != ss || $N_METHOD == aes-128-gcm ]] || fail 'method not changed'
    confirm() { return 0; }
    delete_node 2 > "$ROOT/delete" 2>&1 || fail 'delete'
    [[ ! -e $META_DIR/2.env && ! -e $CONF_DIR/02-$proto.json ]] || fail 'delete persisted'
  ) || exit 1
done

# Port edit failure must restore state and retain the old firewall rules.
(
  fixture ss; N_METHOD=aes-128-gcm; meta_save; write_node_conf
  cp "$META_DIR/1.env" "$ROOT/before.env"
  cp "$(conf_file)" "$ROOT/before.json"
  ask() { echo 1; }; pick_port() { PICKED=25555; }; ask_pub_port() { echo 35555; }
  fw_open() { echo "open $*" >> "$ROOT/rollback-fw"; NODE_FW_ADDED+=("$*"); }
  fw_remove_entry() { echo "close $*" >> "$ROOT/rollback-fw"; }
  apply_config() { restore_snapshot; return 1; }
  if edit_node 1 > "$ROOT/rollback" 2>&1; then fail 'edit failure accepted'; fi
  cmp "$META_DIR/1.env" "$ROOT/before.env" || fail 'rollback metadata'
  cmp "$CONF_DIR/01-ss.json" "$ROOT/before.json" || fail 'rollback config'
  [[ $(cat "$ROOT/rollback-fw") == $'open 25555 both\nclose 25555 both' ]] || fail 'rollback firewall'
) || exit 1

# Updating to an insufficient core must fail before any node setup.
(
  need_core() { :; }; core_version() { echo 1.11.0; }
  ask() { echo 6; }; confirm() { return 0; }; activate_core() { return 0; }
  pick_port() { fail 'unsupported core reached node setup'; }
  if add_node > "$ROOT/old-core" 2>&1; then fail 'old core accepted'; fi
) || exit 1
echo 'PASS: AnyTLS Reality and Shadowsocks regression tests'

# Unattended paths produce all supported protocols with supplied NAT addresses.
for proto in reality ws hy2 tuic anytls anytls-reality ss; do
(
  SB_DIR="$ROOT/cli-$proto"; CONF_DIR="$SB_DIR/conf.d"; META_DIR="$SB_DIR/meta"
  CERT_DIR="$SB_DIR/certs"; BACKUP_DIR="$SB_DIR/backup"
  mkdir -p "$CONF_DIR" "$META_DIR" "$CERT_DIR" "$BACKUP_DIR"
  SB_NON_INTERACTIVE=1 SB_MODE=takeover
  core_version() { echo 1.14.4; }; svc() { return 1; }
  port_in_use() { return 1; }; gen_uuid() { echo 00000000-0000-4000-8000-000000000001; }
  generate_reality_keys() { N_PRIV=private N_PBK=public N_SID=0123456789abcdef; }
  apply_config() { write_nodes_txt; }; show_node() { :; }
  fw_open() { fail 'firewall skip ignored'; }
  args=(--protocol "$proto" --port 24443 --public-port 34443 --address 2001:db8::1 --firewall skip)
  case $proto in reality|anytls-reality) args+=(--sni www.example.com) ;; esac
  parse_add_cli "${args[@]}" || fail 'CLI parse'
  add_node_cli || fail "CLI add $proto"
  meta_load 1 || fail 'CLI metadata'
  [[ $N_PROTO == "$proto" && $N_LPORT == 24443 && $N_PPORT == 34443 && $N_HOST == 2001:db8::1 ]] || fail 'CLI NAT settings'
  jq -e '.inbounds[0].listen_port == 24443' "$(conf_file)" >/dev/null || fail 'CLI configuration'
  [[ -s $SB_DIR/nodes.txt ]] || fail 'CLI sharing output'
) || exit 1
done

(
  printf 'literal-password-$()\n' > "$ROOT/password"
  parse_add_cli --protocol ss --password-file "$ROOT/password" || fail 'password file'
  [[ $CLI_PASS == 'literal-password-$()' ]] || fail 'password interpreted'
  printf 'first\nsecond\n' > "$ROOT/password"
  if parse_add_cli --protocol ss --password-file "$ROOT/password"; then fail 'multiline password'; fi
  for args in '--protocol nope' '--protocol ss --port 65536' '--protocol ss --port 08' \
    '--protocol ss --uuid invalid' '--protocol ss --sni example.com' \
    '--protocol reality --multiplex' '--protocol reality --cert self' \
    '--protocol ws --cert manual' '--protocol reality --port' \
    '--protocol hy2 --method aes-128-gcm' '--protocol ss --unknown value'; do
    if parse_add_cli $args; then fail "invalid arguments accepted: $args"; fi
  done
  parse_add_cli --protocol reality --flow none --multiplex || fail 'valid multiplex parameters'
  SB_NON_INTERACTIVE=1
  if ask 'must not prompt' default < /dev/null; then fail 'unattended prompt accepted'; fi
) || exit 1

(
  cert=$(find "$ROOT/cli-ws/certs" -name fullchain.pem | head -n 1)
  key=${cert%/*}/key.pem
  cert_manual_validate "$cert" "$key" www.bing.com || fail 'manual certificate validation'
  if cert_manual_validate "$cert" "$key" wrong.example; then fail 'wrong certificate hostname'; fi
  other=$(find "$ROOT/cli-hy2/certs" -name key.pem | head -n 1)
  if cert_manual_validate "$cert" "$other" www.bing.com; then fail 'mismatched private key'; fi
) || exit 1

# Relative certificate paths must survive the service's different working directory.
(
  cert=$(find "$ROOT/cli-ws/certs" -name fullchain.pem | head -n 1)
  cd "${cert%/*}" || exit 1
  parse_add_cli --protocol ws --cert manual --domain www.bing.com \
    --cert-file fullchain.pem --key-file key.pem || fail 'relative certificate arguments'
  [[ $CLI_CERT_FILE == /* && $CLI_KEY_FILE == /* ]] || fail 'relative certificate paths persisted'
  cd / || exit 1
  cert_manual_validate "$CLI_CERT_FILE" "$CLI_KEY_FILE" www.bing.com || fail 'certificate paths depend on working directory'
) || exit 1
