#!/usr/bin/env bash
# Source module; loaded by sb.sh.
#---------------------------------------------------------------------
# 生成服务端配置
#---------------------------------------------------------------------
tls_server_json() { # alpn(可空)
  if [[ $N_CERTMODE == builtin ]]; then
    jq -n --arg d "$N_DOMAIN" --arg email "$ACME_EMAIL" --arg v "$N_ACMEV" --arg alpn "$1" '
      {enabled:true,server_name:$d,
       acme:({domain:[$d],data_directory:"/var/lib/sing-box/acme",provider:"letsencrypt",
              disable_http_challenge:($v=="alpn"),disable_tls_alpn_challenge:($v=="http")}
             + (if $email!="" then {email:$email} else {} end))}
      + (if $alpn!="" then {alpn:[$alpn]} else {} end)'
  else
    jq -n --arg d "$N_DOMAIN" --arg c "$N_CERT" --arg k "$N_KEY" --arg alpn "$1" '
      {enabled:true,server_name:$d,certificate_path:$c,key_path:$k}
      + (if $alpn!="" then {alpn:[$alpn]} else {} end)'
  fi
}

#---------------------------------------------------------------------
# 多路复用（sing-mux；仅 VLESS）
#---------------------------------------------------------------------
multiplex_supported() { [[ $N_PROTO == reality || $N_PROTO == ws ]]; }

validate_multiplex() {
  case ${N_MUX:-0} in
    0) return 0 ;;
    1) multiplex_supported || { err "此协议不支持脚本的 multiplex 设置"; return 1; }
       [[ -z $N_FLOW ]] || { err "multiplex 与 Reality Flow 不能同时开启"; return 1; } ;;
    *) err "无效的 multiplex 设置"; return 1 ;;
  esac
}

node_multiplex_json() { # inbound / outbound -> 可合并到节点的 JSON 字段
  validate_multiplex || return 1
  if [[ ${N_MUX:-0} != 1 ]]; then echo '{}'; return 0; fi
  case $1 in
    inbound) echo '{"multiplex":{"enabled":true,"padding":true}}' ;;
    outbound) echo '{"multiplex":{"enabled":true,"protocol":"h2mux","max_connections":4,"min_streams":4,"padding":true}}' ;;
    *) return 1 ;;
  esac
}

toggle_multiplex() {
  multiplex_supported || { warn "multiplex 仅支持 VLESS+Reality / VLESS+WS+TLS"; return 1; }
  if [[ ${N_MUX:-0} == 1 ]]; then
    N_MUX=0; info "multiplex 已关闭，客户端也需关闭 multiplex/smux"
  else
    if [[ -n $N_FLOW ]]; then
      confirm "开启 multiplex 需要关闭 Reality Flow，是否继续?" n || return 1
    fi
    N_FLOW=""; N_MUX=1
    info "multiplex 已开启（客户端需启用多路复用及 padding，关闭 Flow）"
  fi
}

toggle_reality_flow() {
  [[ $N_PROTO == reality ]] || { warn "仅 Reality 支持 Flow"; return 1; }
  if [[ -n $N_FLOW ]]; then
    N_FLOW=""; info "Flow 已关闭"
  else
    if [[ ${N_MUX:-0} == 1 ]]; then
      confirm "开启 Flow 需要关闭 multiplex，是否继续?" n || return 1
    fi
    N_MUX=0; N_FLOW=xtls-rprx-vision
    info "Flow 已开启，客户端需同步开启 Flow 并关闭 multiplex/smux"
  fi
}

write_node_conf() {
  local tag="${N_PROTO}-${N_ID}" listen tls f tmp mux
  mux=$(node_multiplex_json inbound) || return 1
  listen=$(listen_addr); f=$(conf_file); tmp=$(mktemp)
  case $N_PROTO in
    reality)
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$N_LPORT" --arg uuid "$N_UUID" \
        --arg flow "$N_FLOW" --arg sni "$N_SNI" --arg priv "$N_PRIV" --arg sid "$N_SID" --argjson mux "$mux" '
        {inbounds:[{type:"vless",tag:$tag,listen:$listen,listen_port:$port,
          users:[{uuid:$uuid} + (if $flow!="" then {flow:$flow} else {} end)],
          tls:{enabled:true,server_name:$sni,
               reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$priv,short_id:[$sid]}}} + $mux]}' > "$tmp" ;;
    ws)
      tls=$(tls_server_json "")
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$N_LPORT" --arg uuid "$N_UUID" \
        --arg path "$N_WSPATH" --argjson tls "$tls" --argjson mux "$mux" '
        {inbounds:[{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{uuid:$uuid}],
          tls:$tls,transport:{type:"ws",path:$path}} + $mux]}' > "$tmp" ;;
    hy2)
      tls=$(tls_server_json "h3")
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$N_LPORT" --arg pw "$N_PASS" \
        --arg obfs "$N_OBFS" --argjson tls "$tls" '
        {inbounds:[{type:"hysteria2",tag:$tag,listen:$listen,listen_port:$port,users:[{password:$pw}],tls:$tls}
          + (if $obfs!="" then {obfs:{type:"salamander",password:$obfs}} else {} end)]}' > "$tmp" ;;
    tuic)
      tls=$(tls_server_json "h3")
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$N_LPORT" --arg uuid "$N_UUID" \
        --arg pw "$N_PASS" --argjson tls "$tls" '
        {inbounds:[{type:"tuic",tag:$tag,listen:$listen,listen_port:$port,users:[{uuid:$uuid,password:$pw}],
          congestion_control:"bbr",tls:$tls}]}' > "$tmp" ;;
    anytls)
      tls=$(tls_server_json "")
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$N_LPORT" --arg pw "$N_PASS" \
        --argjson tls "$tls" '
        {inbounds:[{type:"anytls",tag:$tag,listen:$listen,listen_port:$port,users:[{password:$pw}],tls:$tls}]}' > "$tmp" ;;
    *) rm -f "$tmp"; return 1 ;;
  esac || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f"; chmod 600 "$f"
}
