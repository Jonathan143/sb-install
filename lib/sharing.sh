#!/usr/bin/env bash
# Source module; loaded by sb.sh.
#---------------------------------------------------------------------
# 分享链接 / 客户端配置
#---------------------------------------------------------------------
node_link() {
  local host name q port
  host=$(host_fmt); name=$(urlenc "${N_NOTE:-$N_PROTO-$N_ID}")
  case $N_PROTO in
    anytls-reality)
      # No cross-client URI convention has been verified for this combination.
      return 1 ;;
    ss)
      validate_ss || return 1
      if [[ $N_METHOD == 2022-* ]]; then
        # SIP002: AEAD-2022 credentials are percent-encoded, not Base64-wrapped.
        q="$(urlenc "$N_METHOD"):$(urlenc "$N_PASS")"
      else
        q=$(printf '%s' "$N_METHOD:$N_PASS" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
      fi
      echo "ss://$q@$host:$N_PPORT#$name" ;;
    reality)
      q="encryption=none&security=reality&sni=$N_SNI&fp=chrome&pbk=$N_PBK&sid=$N_SID&type=tcp"
      [[ -n $N_FLOW ]] && q="$q&flow=$N_FLOW"
      echo "vless://$N_UUID@$host:$N_PPORT?$q#$name" ;;
    ws)
      q="encryption=none&security=tls&sni=$N_DOMAIN&fp=chrome&type=ws&host=$N_DOMAIN&path=$(urlenc "$N_WSPATH")"
      [[ $N_INSECURE == 1 ]] && q="$q&allowInsecure=1"
      echo "vless://$N_UUID@$host:$N_PPORT?$q#$name" ;;
    hy2)
      validate_hy2_hop || return 1
      port=${N_HOP_PORTS:-$N_PPORT}
      q="sni=$(urlenc "$N_DOMAIN")"
      [[ -n $N_OBFS ]] && q="$q&obfs=salamander&obfs-password=$(urlenc "$N_OBFS")"
      [[ $N_INSECURE == 1 ]] && q="$q&insecure=1"
      echo "hysteria2://$(urlenc "$N_PASS")@$host:$port?$q#$name" ;;
    tuic)
      q="congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$N_DOMAIN"
      [[ $N_INSECURE == 1 ]] && q="$q&allow_insecure=1"
      echo "tuic://$N_UUID:$N_PASS@$host:$N_PPORT?$q#$name" ;;
    anytls)
      q="sni=$N_DOMAIN"
      [[ $N_INSECURE == 1 ]] && q="$q&insecure=1"
      echo "anytls://$N_PASS@$host:$N_PPORT?$q#$name" ;;
  esac
}

node_outbound() {
  local tag="${N_NOTE:-$N_PROTO-$N_ID}" ins=false mux
  mux=$(node_multiplex_json outbound) || return 1
  [[ $N_INSECURE == 1 ]] && ins=true
  case $N_PROTO in
    anytls-reality)
      jq -n --arg tag "$tag" --arg server "$N_HOST" --argjson port "$N_PPORT" --arg pw "$N_PASS" \
        --arg sni "$N_SNI" --arg pbk "$N_PBK" --arg sid "$N_SID" '
        {type:"anytls",tag:$tag,server:$server,server_port:$port,password:$pw,
         tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},
              reality:{enabled:true,public_key:$pbk,short_id:$sid}}}' ;;
    ss)
      validate_ss || return 1
      jq -n --arg tag "$tag" --arg server "$N_HOST" --argjson port "$N_PPORT" \
        --arg method "$N_METHOD" --arg pw "$N_PASS" '
        {type:"shadowsocks",tag:$tag,server:$server,server_port:$port,method:$method,password:$pw}' ;;
    reality)
      jq -n --arg tag "$tag" --arg server "$N_HOST" --argjson port "$N_PPORT" --arg uuid "$N_UUID" \
        --arg flow "$N_FLOW" --arg sni "$N_SNI" --arg pbk "$N_PBK" --arg sid "$N_SID" --argjson mux "$mux" '
        {type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid,
         tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},
              reality:{enabled:true,public_key:$pbk,short_id:$sid}}} + $mux
        | if $flow!="" then .flow=$flow else . end' ;;
    ws)
      jq -n --arg tag "$tag" --arg server "$N_HOST" --argjson port "$N_PPORT" --arg uuid "$N_UUID" \
        --arg d "$N_DOMAIN" --arg path "$N_WSPATH" --argjson ins "$ins" --argjson mux "$mux" '
        {type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid,
         tls:{enabled:true,server_name:$d,insecure:$ins,utls:{enabled:true,fingerprint:"chrome"}},
         transport:{type:"ws",path:$path,headers:{Host:$d}}} + $mux' ;;
    hy2)
      validate_hy2_hop || return 1
      jq -n --arg tag "$tag" --arg server "$N_HOST" --argjson port "$N_PPORT" --arg pw "$N_PASS" \
        --arg d "$N_DOMAIN" --arg obfs "$N_OBFS" --argjson ins "$ins" \
        --arg ports "${N_HOP_PORTS:-}" --arg interval "${N_HOP_INTERVAL:-30}" '
        {type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$pw,
         tls:{enabled:true,server_name:$d,insecure:$ins,alpn:["h3"]}}
        | if $ports!="" then del(.server_port) | .server_ports=[$ports|gsub("-"; ":")] | .hop_interval=($interval+"s") else . end
        | if $obfs!="" then .obfs={type:"salamander",password:$obfs} else . end' ;;
    tuic)
      jq -n --arg tag "$tag" --arg server "$N_HOST" --argjson port "$N_PPORT" --arg uuid "$N_UUID" \
        --arg pw "$N_PASS" --arg d "$N_DOMAIN" --argjson ins "$ins" '
        {type:"tuic",tag:$tag,server:$server,server_port:$port,uuid:$uuid,password:$pw,
         congestion_control:"bbr",udp_relay_mode:"native",
         tls:{enabled:true,server_name:$d,insecure:$ins,alpn:["h3"]}}' ;;
    anytls)
      jq -n --arg tag "$tag" --arg server "$N_HOST" --argjson port "$N_PPORT" --arg pw "$N_PASS" \
        --arg d "$N_DOMAIN" --argjson ins "$ins" '
        {type:"anytls",tag:$tag,server:$server,server_port:$port,password:$pw,
         tls:{enabled:true,server_name:$d,insecure:$ins}}' ;;
  esac
}

node_mihomo_ss() {
  [[ $N_PROTO == ss ]] || return 1
  validate_ss || return 1
  # JSON-quoted strings are also valid YAML scalars, including quotes and newlines.
  jq -nr --arg name "${N_NOTE:-ss-$N_ID}" --arg server "$N_HOST" --argjson port "$N_PPORT" \
    --arg method "$N_METHOD" --arg pw "$N_PASS" '
    "proxies:\n  - name: \($name|tojson)\n    type: ss\n    server: \($server|tojson)\n    port: \($port)\n    cipher: \($method|tojson)\n    password: \($pw|tojson)\n    udp: true"'
}

node_mihomo_smux() { # 添加到 mihomo 的单个节点内，与 server / port 同级
  validate_multiplex || return 1
  multiplex_supported || return 1
  if [[ ${N_MUX:-0} != 1 ]]; then printf 'smux:\n  enabled: false\n'; return 0; fi
  cat <<'EOF'
smux:
  enabled: true
  protocol: h2mux
  max-connections: 4
  min-streams: 4
  only-tcp: true
  padding: true
EOF
}

show_node() {
  local RED GREEN YELLOW CYAN PLAIN BOLD DIM
  ui_colors 1
  local link
  meta_load "$1" || { err "节点 $1 不存在"; return 1; }
  echo "=================================================="
  echo "编号: $N_ID    协议: $(proto_label)    备注: $N_NOTE"
  echo "地址: $N_HOST    对外端口: $N_PPORT    监听端口: $N_LPORT"
  if [[ $N_PROTO == hy2 ]]; then
    echo "端口跳跃: ${N_HOP_PORTS:-关闭}${N_HOP_PORTS:+（间隔 ${N_HOP_INTERVAL:-30} 秒）}"
    if [[ -n ${N_HOP_PORTS:-} ]]; then
      echo "商家需将全部跳跃端口的 UDP 转发至监听端口 ${N_LPORT}。"
      echo "sing-box 客户端需 1.11+；链接携带范围但不携带间隔，导入后请核对下方配置。"
    fi
  fi
  [[ -n $N_DOMAIN ]] && echo "域名/SNI: $N_DOMAIN"
  [[ $N_PROTO == reality ]] && echo "SNI: $N_SNI    Flow: ${N_FLOW:-关闭}"
  if [[ $N_PROTO == anytls-reality ]]; then
    echo "SNI: $N_SNI"
    echo "兼容性: Clash Verge Rev / Mihomo 不支持 AnyTLS + REALITY。"
    echo "其他客户端需支持此组合；以下提供 sing-box outbound 配置。"
  fi
  if [[ $N_PROTO == ss ]]; then
    echo "加密方式: $N_METHOD    传输: TCP + UDP"
    [[ $N_METHOD != 2022-* ]] || echo "SS2022: 客户端版本必须支持所选加密方式。"
  fi
  if multiplex_supported; then
    if [[ ${N_MUX:-0} == 1 ]]; then
      echo "Multiplex: 开启（h2mux，padding 开启）"
      echo "分享链接/二维码不携带 multiplex 设置，导入后需同步下方客户端配置。"
    else
      echo "Multiplex: 关闭（客户端 multiplex/smux 也应关闭）"
    fi
  fi
  [[ $N_INSECURE == 1 ]] && echo "${YELLOW}自签证书：客户端需开启 insecure${PLAIN}"
  echo "--------------------------------------------------"
  if link=$(node_link); then
    echo "分享链接:"; echo "$link"
    command -v qrencode >/dev/null && { echo; qrencode -t ANSIUTF8 "$link"; }
  else
    echo "此组合暂不生成分享链接或二维码，请使用下方客户端配置。"
  fi
  echo "--------------------------------------------------"
  echo "sing-box 客户端 outbound:"; node_outbound
  if [[ $N_PROTO == ss ]]; then
    echo "--------------------------------------------------"
    echo "Mihomo 配置（将节点合并到现有 proxies 列表）:"
    node_mihomo_ss
  fi
  if [[ $N_PROTO == hy2 ]]; then
    echo "--------------------------------------------------"
    echo "Mihomo 配置（将节点合并到现有 proxies 列表）:"
    node_mihomo_hy2
  fi
  if multiplex_supported; then
    echo "--------------------------------------------------"
    echo "mihomo 配置片段（放入对应节点内，与 server / port 同级）:"
    node_mihomo_smux
    [[ ${N_MUX:-0} != 1 ]] || echo "客户端不要设置 flow: xtls-rprx-vision。"
  fi
  echo "=================================================="
}

write_nodes_txt() {
  local id
  { for id in $(list_ids); do meta_load "$id" && {
    echo "# [$id] $(proto_label) $N_NOTE"
    if [[ $N_PROTO == hy2 && -n ${N_HOP_PORTS:-} ]]; then
      echo "# 端口跳跃 ${N_HOP_PORTS}，间隔 ${N_HOP_INTERVAL:-30} 秒；链接不携带间隔，请运行 sb info $id 核对客户端配置。"
    fi
    [[ ${N_MUX:-0} != 1 ]] || echo "# multiplex 已开启：链接不携带此设置，请运行 sb info $id 获取客户端配置（需 padding，关闭 Flow）。"
    if [[ $N_PROTO == anytls-reality ]]; then
      echo "# Mihomo 不支持此组合；无通用分享链接，请运行 sb info $id 获取 sing-box 配置。"
    else
      [[ $N_PROTO != ss || $N_METHOD != 2022-* ]] || echo "# SS2022：客户端版本必须支持 $N_METHOD。"
      node_link
    fi
    echo
  }; done; } > "$SB_DIR/nodes.txt"
  chmod 600 "$SB_DIR/nodes.txt"
}
