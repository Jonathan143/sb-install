#!/usr/bin/env bash
# Local end-to-end proxy routing, no root, public network or service manager required.
source "$(dirname "$0")/../sb.sh"
[[ -n ${TEST_SING_BOX:-} && -x $TEST_SING_BOX ]] || { echo 'Set TEST_SING_BOX to an executable sing-box'; exit 1; }
ROOT=$(mktemp -d) || exit 1
SB_DIR="$ROOT/state"; CONF_DIR="$SB_DIR/conf.d"; META_DIR="$SB_DIR/meta"
SB_BIN=$TEST_SING_BOX; SB_MODE=takeover
entry_pid=''; exit_pid=''; http_pid=''
cleanup() {
  local pid
  for pid in "$entry_pid" "$exit_pid" "$http_pid"; do
    [[ -z $pid ]] || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
  done
  rm -rf "$ROOT"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; cat "$ROOT"/*.log >&2; exit 1; }
mkdir -p "$CONF_DIR" "$META_DIR"
port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
target_port=$(port); entry_port=$(port); exit_port=$(port)
printf '%s' 'egress-ok' > "$ROOT/result"
python3 -m http.server "$target_port" --bind 127.0.0.1 --directory "$ROOT" > "$ROOT/http.log" 2>&1 & http_pid=$!
meta_reset; N_ID=1; N_PROTO=test; meta_save
jq -n --argjson port "$entry_port" '{inbounds:[{type:"http",tag:"test-1",listen:"127.0.0.1",listen_port:$port}]}' > "$CONF_DIR/01-entry.json"
start_entry() {
  if [[ -n $entry_pid ]]; then kill "$entry_pid"; wait "$entry_pid" 2>/dev/null; entry_pid=''; fi
  route_refresh || fail 'refresh'
  "$SB_BIN" check -C "$CONF_DIR" > "$ROOT/check.log" 2>&1 || fail 'check'
  "$SB_BIN" run -C "$CONF_DIR" > "$ROOT/entry.log" 2>&1 & entry_pid=$!
  sleep 1
  kill -0 "$entry_pid" 2>/dev/null || fail 'entry startup'
}
request() {
  curl -fsS --noproxy '' --proxy "http://127.0.0.1:$entry_port" --max-time 3 "http://$1:$target_port/result" 2>/dev/null
}
uuid=12345678-1234-1234-1234-123456789abc
for protocol in ss vless; do
  for kind in domain domain_suffix ip_cidr; do
    if [[ $protocol == ss ]]; then
      parsed=$(route_parse_link "ss://aes-128-gcm:pass@127.0.0.1:$exit_port") || fail 'SS import'
      inbound=$(jq -n --argjson port "$exit_port" '{type:"shadowsocks",tag:"landing",listen:"127.0.0.1",listen_port:$port,method:"aes-128-gcm",password:"pass"}')
    else
      parsed=$(route_parse_link "vless://$uuid@127.0.0.1:$exit_port?security=none&type=tcp") || fail 'VLESS import'
      inbound=$(jq -n --argjson port "$exit_port" --arg uuid "$uuid" '{type:"vless",tag:"landing",listen:"127.0.0.1",listen_port:$port,users:[{uuid:$uuid}]}')
    fi
    jq -n --argjson inbound "$inbound" '{inbounds:[$inbound],outbounds:[{type:"direct",tag:"direct"}]}' > "$ROOT/landing.json"
    "$SB_BIN" run -c "$ROOT/landing.json" > "$ROOT/landing.log" 2>&1 & exit_pid=$!
    value=localhost; host=localhost
    if [[ $kind == ip_cidr ]]; then value=127.0.0.1/32; host=127.0.0.1; fi
    state=$(jq -n --argjson parsed "$parsed" --arg kind "$kind" --arg value "$value" '{next_id:2,default:"direct",exits:[{id:"sb-egress-1",name:"test",config:$parsed.config}],rules:[{kind:$kind,values:[$value],outbound:"sb-egress-1",enabled:true}]}')
    route_write_json "$META_DIR/routing.json" "$state"
    start_entry
    [[ $(request "$host") == egress-ok ]] || fail "$protocol $kind forward"
    if [[ $kind == ip_cidr ]]; then
      [[ $(request localhost) == egress-ok ]] || fail 'resolve domain before IP rule'
    fi
    # With a domain-only rule, numeric targets should use default direct.
    kill "$exit_pid"; wait "$exit_pid" 2>/dev/null; exit_pid=''
    if request "$host" > /dev/null; then fail "$protocol $kind leaked to direct"; fi
    if [[ $kind == ip_cidr ]] && request localhost >/dev/null; then fail 'resolved IP rule leaked to direct'; fi
    if [[ $kind != ip_cidr ]]; then
      [[ $(request 127.0.0.1) == egress-ok ]] || fail 'unmatched default direct'
    fi
    route_write_json "$META_DIR/routing.json" "$(jq '.rules[0].enabled=false' <<<"$state")"
    start_entry
    [[ $(request "$host") == egress-ok ]] || fail 'disabled rule default direct'
    echo "PASS: $protocol $kind routed, no fallback, disabled rule direct"
  done
done

# Exercise the probe helper against the local target instead of the public IP service.
printf '%s' '127.0.0.1' > "$ROOT/ip"
"$SB_BIN" run -c "$ROOT/landing.json" > "$ROOT/landing.log" 2>&1 & exit_pid=$!
sleep 1
(
  curl() {
    local arg args=()
    for arg in "$@"; do
      if [[ $arg == https://api.ipify.org ]]; then args+=("http://127.0.0.1:$target_port/ip")
      else args+=("$arg"); fi
    done
    command curl "${args[@]}"
  }
  route_probe "$state" sb-egress-1 || fail 'isolated probe'
)
