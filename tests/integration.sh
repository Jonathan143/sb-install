#!/usr/bin/env bash
# Use an official local binary; no installation, external proxy traffic or CA requests.
source "$(dirname "$0")/../sb.sh"
[[ -n ${SB_TEST_CORE:-} && -x $SB_TEST_CORE ]] || { echo 'Set SB_TEST_CORE to an executable sing-box binary' >&2; exit 1; }
ROOT=$(mktemp -d) || exit 1
SB_DIR="$ROOT/config"; CONF_DIR="$SB_DIR/conf.d"; META_DIR="$SB_DIR/meta"
CERT_DIR="$SB_DIR/certs"; BACKUP_DIR="$SB_DIR/backup"; SB_WORKDIR="$ROOT/work"
SB_BIN="$ROOT/sing-box"; SB_MODE=takeover; SB_SERVICE="sb-integration-$$"
ACME_EMAIL=test@example.test
server_pid=""; client_pid=""; http_pid=""; service_written=0
cleanup() {
  if ((service_written)); then
    svc stop >/dev/null 2>&1 || :
    svc disable >/dev/null 2>&1 || :
    rm -f "/etc/systemd/system/$SB_SERVICE.service" "/etc/init.d/$SB_SERVICE"
    if has_systemd; then systemctl daemon-reload; fi
  fi
  local child
  for child in "$server_pid" "$client_pid" "$http_pid"; do
    [[ -z $child ]] || { kill "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :; }
  done
  rm -rf "$ROOT"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; cat "$ROOT"/*.log >&2 2>/dev/null; exit 1; }
mkdir -p "$CONF_DIR" "$META_DIR" "$CERT_DIR" "$BACKUP_DIR" "$SB_WORKDIR"
install -m 755 "$SB_TEST_CORE" "$SB_BIN" || fail 'copy core'
VERSION=$(core_version) || fail 'core version'
listen_addr() { echo 127.0.0.1; }
port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# Check every generated inbound and outbound with the actual core parser.
for protocol in reality ws hy2 tuic anytls anytls-reality ss; do
  rm -f "$CONF_DIR"/*.json
  meta_reset
  N_ID=1 N_PROTO=$protocol N_LPORT=24443 N_PPORT=24443 N_HOST=127.0.0.1
  N_UUID=00000000-0000-4000-8000-000000000001 N_PASS=test-password N_SNI=example.test
  N_DOMAIN=example.test N_WSPATH=/ws N_METHOD=aes-128-gcm
  case $protocol in
    reality|anytls-reality) generate_reality_keys || fail 'Reality keys' ;;
    ws|hy2|tuic|anytls) cert_self || fail 'self certificate' ;;
  esac
  write_node_conf || fail "$protocol generation"
  sb_args
  "$SB_BIN" "${SB_ARGS[@]}" check > "$ROOT/check.log" 2>&1 || fail "$VERSION $protocol inbound"
  node_outbound | jq '{outbounds:[.]}' > "$ROOT/client-check.json" || fail 'outbound generation'
  "$SB_BIN" -D "$SB_WORKDIR" -c "$ROOT/client-check.json" check > "$ROOT/check.log" 2>&1 || fail "$VERSION $protocol outbound"
  case $protocol in
    ws|hy2|tuic|anytls)
      N_CERTMODE=builtin N_ACMEV=http
      write_node_conf || fail 'builtin certificate generation'
      "$SB_BIN" "${SB_ARGS[@]}" check > "$ROOT/check.log" 2>&1 || fail "$VERSION $protocol builtin ACME" ;;
  esac
done

# A loopback HTTP request travels through a real Shadowsocks server and client.
rm -f "$CONF_DIR"/*.json
meta_reset
N_ID=1 N_PROTO=ss N_HOST=127.0.0.1
N_LPORT=$(port) || fail 'allocate loopback port'
N_PPORT=$N_LPORT N_METHOD=aes-128-gcm N_PASS=integration-password
write_base && meta_save && write_node_conf || fail 'server generation'
client_port=$(port) || fail 'allocate client port'
http_port=$(port) || fail 'allocate HTTP port'
node_outbound | jq --argjson port "$client_port" '{inbounds:[{type:"mixed",listen:"127.0.0.1",listen_port:$port}],outbounds:[.]}' > "$ROOT/client.json" || fail 'client config'
printf 'sb-integration-ok\n' > "$ROOT/probe"
python3 -m http.server "$http_port" --bind 127.0.0.1 --directory "$ROOT" > "$ROOT/http.log" 2>&1 &
http_pid=$!
"$SB_BIN" -D "$SB_WORKDIR" -c "$ROOT/client.json" run > "$ROOT/client.log" 2>&1 &
client_pid=$!
case ${SB_TEST_SERVICE:-process} in
  systemd|openrc)
    [[ $EUID == 0 ]] || fail 'service integration needs root in an isolated CI host'
    if [[ $SB_TEST_SERVICE == systemd ]]; then has_systemd || fail 'systemd unavailable'
    else command -v rc-service >/dev/null || fail 'OpenRC unavailable'; fi
    service_written=1
    write_service && svc enable && svc start || fail 'service start'
    restart_service_checked || fail 'service restart' ;;
  process)
    sb_args
    "$SB_BIN" "${SB_ARGS[@]}" run > "$ROOT/server.log" 2>&1 &
    server_pid=$! ;;
  *) fail 'unknown SB_TEST_SERVICE' ;;
esac
request() {
  curl -fsS --noproxy '' --proxy "socks5h://127.0.0.1:$client_port" \
    --connect-timeout 1 --max-time 2 "http://127.0.0.1:$http_port/probe" 2>/dev/null
}
response=""
for attempt in $(seq 1 30); do
  response=$(request) && break
  sleep 0.1
done
[[ $response == sb-integration-ok ]] || fail 'Shadowsocks request'
if ((service_written)); then
  # Reinstall the supplied version through the same checked activation path.
  install_core() { install -m 755 "$SB_TEST_CORE" "$SB_BIN.new" && mv -f "$SB_BIN.new" "$SB_BIN"; }
  activate_core "$VERSION" || fail 'real service core activation'
  [[ $(request) == sb-integration-ok ]] || fail 'request after core activation'
  svc stop || fail 'service stop'
  if svc is-active; then fail 'service remained active after stop'; fi
fi
echo "PASS: sing-box $VERSION configs, builtin ACME and Shadowsocks traffic (${SB_TEST_SERVICE:-process})"
