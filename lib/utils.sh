#!/usr/bin/env bash
# Source module; loaded by sb.sh.
rand_str() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-16}"; echo; }
gen_uuid() { cat /proc/sys/kernel/random/uuid; }
urlenc() { jq -rn --arg s "$1" '$s|@uri'; }
version_ge() { [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1) == "$2" ]]; }
listen_addr() { [[ -e /proc/net/if_inet6 ]] && echo "::" || echo "0.0.0.0"; }

proto_label() {
  case ${1:-$N_PROTO} in
    reality) echo "VLESS+Reality" ;; ws) echo "VLESS+WS+TLS" ;; hy2) echo "Hysteria2" ;;
    tuic) echo "TUIC v5" ;; anytls) echo "AnyTLS" ;;
    anytls-reality) echo "AnyTLS+Reality" ;; ss) echo "Shadowsocks" ;;
  esac
}
proto_net() { case ${1:-$N_PROTO} in hy2|tuic) echo udp ;; ss) echo both ;; *) echo tcp ;; esac; }
uses_reality() { [[ $N_PROTO == reality || $N_PROTO == anytls-reality ]]; }
