#!/usr/bin/env bash
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
SB_DIR="$ROOT/state"; CONF_DIR="$SB_DIR/conf.d"; META_DIR="$SB_DIR/meta"; BACKUP_DIR="$SB_DIR/backup"
mkdir -p "$CONF_DIR" "$META_DIR" "$BACKUP_DIR"
uuid=12345678-1234-1234-1234-123456789abc
link="vless://$uuid@[2001:db8::1]:443?type=tcp&security=reality&sni=example.com&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd&fp=chrome&flow=xtls-rprx-vision#%E7%BE%8E%E5%9B%BD"
p=$(route_parse_link "$link") || fail 'parse Reality'
jq -e '.name == "美国" and .config.server == "2001:db8::1" and .config.tls.reality.short_id == "abcd" and .config.flow == "xtls-rprx-vision"' <<<"$p" >/dev/null || fail 'Reality fields'
p=$(route_parse_link "vless://$uuid@host.example:443?type=ws&security=tls&path=%2Fws%3Fed%3D2048&host=cdn.example&alpn=h2,http%2F1.1#test") || fail 'parse WS'
jq -e '.config.transport.path == "/ws?ed=2048" and .config.tls.alpn == ["h2","http/1.1"]' <<<"$p" >/dev/null || fail 'WS fields'
for bad in \
  "vless://$uuid@host:443?type=xhttp" \
  "vless://$uuid@host:443?security=reality" \
  "vless://$uuid@host:443?type=tcp&type=ws" \
  "vless://$uuid@host:443?unknown=x" \
  "vless://$uuid@host:443?path=%00" \
  "vless://$uuid@host:443?type=ws&flow=xtls-rprx-vision" \
  "vless://$uuid@host:443?security=none&sni=host" \
  "vless://bad@host:443" \
  "vless://$uuid@host:65536" \
  'ss://YWVzLTEyOC1nY206cGFzcw@host:443?plugin=obfs-local'; do
  if route_parse_link "$bad" > /dev/null 2>&1; then fail "unsupported link accepted"; fi
done
for uri in \
  'ss://YWVzLTEyOC1nY206cGFzcw@host:443#test' \
  'ss://aes-128-gcm:pass@host:443' \
  "ss://$(printf 'aes-128-gcm:pass@host:443' | openssl base64 -A)"; do
  p=$(route_parse_link "$uri") || fail 'SS parse'
  jq -e '.config.password == "pass" and .config.method == "aes-128-gcm"' <<<"$p" >/dev/null || fail 'SS fields'
done
p=$(route_parse_link 'ss://aes-128-gcm:a%3Ab%40c%25%5C%22@host:443') || fail 'SS escaping'
jq -e '.config.password == "a:b@c%\\\""' <<<"$p" >/dev/null || fail 'SS password corrupted'
core_version() { echo 1.12.0; }
meta_reset; N_ID=1; N_PROTO=reality; meta_save || fail 'meta'
state=$(jq -n --argjson p "$p" '{next_id:2,default:"direct",exits:[{id:"sb-egress-1",name:"exit",config:$p.config}],rules:[
  {kind:"domain_suffix",values:["example.com"],outbound:"sb-egress-1",enabled:true},
  {kind:"domain",values:["disabled.example"],outbound:"direct",enabled:false},
  {kind:"ip_cidr",values:["203.0.113.0/24"],outbound:"sb-egress-1",enabled:true}]}')
route_write_json "$META_DIR/routing.json" "$state" || fail 'save'
route_refresh || fail 'generate'
jq -e '.route.rules | length == 5 and .[0].action == "sniff" and .[1].domain_suffix == ["example.com"] and .[2].action == "resolve" and .[3].ip_cidr == ["203.0.113.0/24"] and .[4].outbound == "sb-egress-direct" and all(.[]; .inbound == ["reality-1"])' "$CONF_DIR/00-egress.json" >/dev/null || fail 'rule ordering/scope'
[[ $N_ID == 1 && $N_PROTO == reality ]] || fail 'metadata clobbered'
route_show > "$ROOT/show" || fail 'render routing summary'
if grep -q 'password\|a:b@c' "$ROOT/show"; then fail 'credential leak'; fi
snapshot || fail 'snapshot'
route_write_json "$META_DIR/routing.json" '{}' || fail 'mutation'
restore_snapshot || fail 'restore'
[[ $(route_load) == "$state" ]] || fail 'state not restored'
# Rebuild scope when adding/removing nodes.
meta_reset; N_ID=2; N_PROTO=ss; meta_save
route_refresh || fail 'refresh new node'
jq -e '.route.rules[0].inbound == ["reality-1","ss-2"]' "$CONF_DIR/00-egress.json" >/dev/null || fail 'new inbound missing'
rm "$META_DIR/1.env" "$META_DIR/2.env"
route_refresh || fail 'refresh zero nodes'
jq -e '.route.rules == []' "$CONF_DIR/00-egress.json" >/dev/null || fail 'empty scope became global'
SB_MODE=coexist
printf '%s\n' '{"route":{"final":"existing"}}' > "$SB_DIR/config.json"
route_refresh || fail 'coexist without existing rules'
jq -e '.route | has("final") | not' "$CONF_DIR/00-egress.json" >/dev/null || fail 'global default overwritten'
jq -e '.route.final == "existing"' "$SB_DIR/config.json" >/dev/null || fail 'coexist config rewritten'
printf '%s\n'  '{"route":{"rules":[{"domain":["example.com"],"outbound":"existing"}]}}' > "$SB_DIR/config.json"
if route_refresh >/dev/null 2>&1; then fail 'unsafe coexist precedence accepted'; fi
SB_MODE=takeover
# Exercise real transaction failure and rollback without services or root.
meta_reset; N_ID=1; N_PROTO=ss; meta_save
route_refresh
cp "$CONF_DIR/00-egress.json" "$ROOT/before"
svc() { return 1; }
refresh_builtin_acme_configs() { return 0; }
SB_BIN=/usr/bin/false
if route_save "$(jq '.default="sb-egress-1"' <<<"$state")" >/dev/null 2>&1; then fail 'failed check accepted'; fi
[[ $(route_load) == "$state" ]] || fail 'failed apply did not restore state'
cmp "$ROOT/before" "$CONF_DIR/00-egress.json" || fail 'failed apply did not restore config'
if [[ -n ${TEST_SING_BOX:-} ]]; then
  "$TEST_SING_BOX" check -c "$ROOT/before" || fail 'real sing-box check'
  for uri in "$link" \
    "vless://$uuid@example.com:443?type=ws&security=tls&path=%2Fws&host=example.com" \
    "vless://$uuid@example.com:443?type=grpc&security=tls&serviceName=test" \
    "vless://$uuid@example.com:443?type=http&security=tls&path=%2Ftest" \
    "ss://2022-blake3-aes-256-gcm:$(openssl rand -base64 32)@127.0.0.1:443"; do
    route_parse_link "$uri" | jq '{dns:{servers:[{type:"local",tag:"test-dns"}]},outbounds:[.config + {tag:"test",domain_resolver:"test-dns"}]}' > "$ROOT/parsed.json" || fail 'core fixture'
    "$TEST_SING_BOX" check -c "$ROOT/parsed.json" || fail 'imported protocol core check'
  done
else
  echo 'SKIP: real sing-box validation (set TEST_SING_BOX)'
fi
# Updating a link preserves the stable ID, references and next-ID counter.
(
  ask() {
    case $1 in
      粘贴*) printf '%s' "vless://$uuid@new.example:443?type=raw&security=tls&headerType=none" ;;
      *) echo renamed ;;
    esac
  }
  route_save() { printf '%s' "$1" > "$ROOT/updated"; }
  route_import "$state" sb-egress-1 >/dev/null || fail 'update link'
)
jq -e '.next_id == 2 and (.exits|length) == 1 and .exits[0].id == "sb-egress-1" and .exits[0].name == "renamed" and .exits[0].config.server == "new.example" and .rules[0].outbound == "sb-egress-1"' "$ROOT/updated" >/dev/null || fail 'update lost references'
# Newline/NUL payloads and malformed escapes must not silently change credentials.
for bad in 'ss://YWVzLTEyOC1nY206YQBi@host:443' "vless://$uuid@host:443?type=tcp&headerType=http" "vless://$uuid@host:443#%0Aname"; do
  if route_parse_link "$bad" >/dev/null 2>&1; then fail 'malformed payload accepted'; fi
done
# Menu operations: toggle, move, delete, default selection and reference protection.
(
  META_DIR="$ROOT/ui-meta"; mkdir -p "$META_DIR"
  route_write_json "$META_DIR/routing.json" "$state"
  need_core() { return 0; }
  route_save() { route_write_json "$META_DIR/routing.json" "$1"; }
  routing_menu <<'INPUT' > "$ROOT/menu.log" 2>&1
6
1
7
1
3
8
1
9
2
3
1
4
2
example.org, sub.example.org
2
0
INPUT
  jq -e '.default == "sb-egress-1" and (.exits|length) == 1 and (.rules|length) == 3 and .rules[0].kind == "ip_cidr" and .rules[1].enabled == false and .rules[2].values == ["example.org","sub.example.org"]' "$META_DIR/routing.json" >/dev/null || fail 'menu mutations'
) || fail 'menu workflow'
# Exit selection uses numbers, supports cancellation, and excludes direct when managing.
[[ $(route_pick_exit "$state" <<< 2) == sb-egress-1 ]] || fail 'numbered exit selection'
[[ $(route_pick_exit "$state" managed <<< 1) == sb-egress-1 ]] || fail 'managed selection'
if route_pick_exit "$state" <<< q; then fail 'exit selection did not cancel'; fi
# Editing without changing fields must preserve a disabled rule and its target.
(
  route_save() { printf '%s' "$1" > "$ROOT/edited"; }
  route_edit_rule "$state" 1 <<< $'\n\n' > /dev/null || fail 'edit defaults'
) || fail 'edit workflow'
jq -e --argjson original "$state" '.rules == $original.rules' "$ROOT/edited" >/dev/null || fail 'edit changed defaults or enabled state'
(
  route_save() { fail 'cancel saved a rule'; }
  route_edit_rule "$state" <<< 0
  route_import "$state" <<< q
) || fail 'cancel workflow'
# Duplicate additions and edits never save/restart, including disabled rules,
# repeated values, and different value order. Different targets remain valid.
(
  route_save() { printf '%s' "$1" > "$ROOT/dedup-saved"; }
  duplicate_state=$(jq '.rules[0].values=["example.com","sub.example.com"]' <<<"$state")
  route_edit_rule "$duplicate_state" <<< $'2\nSUB.EXAMPLE.COM, example.com, example.com\n2' > "$ROOT/dedup-log" 2>&1 || fail 'duplicate add'
  [[ ! -e $ROOT/dedup-saved ]] || fail 'duplicate addition saved'
  grep -q '第 1 条' "$ROOT/dedup-log" || fail 'missing duplicate location'
  route_edit_rule "$state" <<< $'1\ndisabled.example\n1' > /dev/null 2>&1 || fail 'disabled duplicate'
  [[ ! -e $ROOT/dedup-saved ]] || fail 'disabled duplicate saved'
  route_edit_rule "$state" 2 <<< $'2\nexample.com\n2' > /dev/null 2>&1 || fail 'duplicate edit'
  [[ ! -e $ROOT/dedup-saved ]] || fail 'duplicate edit saved'
  route_edit_rule "$state" <<< $'2\nexample.com, example.com\n1' > /dev/null 2>&1 || fail 'different target'
  jq -e '.rules[-1].outbound == "direct" and .rules[-1].values == ["example.com"]' "$ROOT/dedup-saved" >/dev/null || fail 'different target rejected or repeated values retained'
) || fail 'duplicate rule workflow'
# Invalid match input stays in the same step and restores the raw draft.
(
  route_save() { printf '%s' "$1" > "$ROOT/retry-saved"; }
  ask_edit() {
    printf '%s\n' "${2:-}" >> "$ROOT/retry-defaults"
    ask "$@"
  }
  route_edit_rule "$state" <<< $'2\nchatgpt.com,openai.com,,ai.com\nhttps://chatgpt.com\nchatgpt.com,openai.com,ai.com\n2' > "$ROOT/retry-log" 2>&1 || fail 'retry domain input'
  grep -Fxq 'chatgpt.com,openai.com,,ai.com' "$ROOT/retry-defaults" || fail 'raw draft not restored'
  grep -Fxq 'https://chatgpt.com' "$ROOT/retry-defaults" || fail 'invalid domain not restored'
  if grep -q 'jq: error' "$ROOT/retry-log"; then fail 'raw jq error leaked'; fi
  jq -e '.rules[-1].kind == "domain_suffix" and .rules[-1].values == ["ai.com","chatgpt.com","openai.com"]' "$ROOT/retry-saved" >/dev/null || fail 'retry lost match type or values'
  route_edit_rule "$state" <<< $'3\nnot-an-ip\n192.0.2.1\n1' > /dev/null 2>&1 || fail 'retry IP input'
  jq -e '.rules[-1].values == ["192.0.2.1/32"]' "$ROOT/retry-saved" >/dev/null || fail 'IP correction not saved'
  rm "$ROOT/retry-saved"
  route_edit_rule "$state" <<< $'2\nbad,,value\nq' > /dev/null 2>&1 || fail 'cancel retry'
  if route_edit_rule "$state" <<< $'2\nbad,,value' > /dev/null 2>&1; then fail 'retry EOF accepted'; fi
  [[ ! -e $ROOT/retry-saved ]] || fail 'cancel/EOF saved a rule'
) || fail 'match input retry workflow'
echo 'PASS: egress URI parsing, scoped routing, snapshots and rollback'
