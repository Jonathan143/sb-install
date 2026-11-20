#!/usr/bin/env bash
# Source module; loaded by sb.sh.
main() {
  local SB_NON_INTERACTIVE=0 SB_SCRIPT_URL_OVERRIDE=$SCRIPT_URL
  if [[ ${1:-} == add && $# -gt 1 ]]; then
    shift
    [[ ${1:-} != --help && ${1:-} != -h ]] || { add_usage; return 0; }
    parse_add_cli "$@" || return 1
    SB_NON_INTERACTIVE=1
    set -- add
  fi
  case ${1:-} in
    -h|--help|help) usage; return 0 ;;
    -v|--version|version) echo "sb v$SB_VERSION"; return 0 ;;
  esac
  if [[ ${1:-} == update ]]; then
    if (($# > 2)) || [[ -n ${2:-} && ${2:-} != --beta ]]; then
      err '用法: sb update [--beta]'; return 1
    fi
  fi
  case ${1:-} in
    status|doctor|config|list|ls|info|log|logs)
      load_conf
      readonly_dispatch "$@"; return $? ;;
    bbr)
      if (($# > 2)); then err '用法: sb bbr [show|enable]'; return 1; fi
      case ${2:-} in
        show) bbr_show; return $? ;;
        ""|enable) ;;
        *) err '用法: sb bbr [show|enable]'; return 1 ;;
      esac ;;
    dns) if [[ ${2:-} == show ]]; then system_dns_show; return $?; fi ;;
    route) if [[ ${2:-} == show ]]; then load_conf; readonly_require jq && route_show; return $?; fi ;;
  esac
  [[ $EUID -eq 0 ]] || die "请使用 root 用户运行"
  acquire_lock || return 1
  if [[ ${1:-} == bbr ]]; then
    if [[ ${2:-} == enable ]]; then bbr_enable; else bbr_menu; fi
    return $?
  fi
  if [[ ${1:-} == dns ]]; then
    case ${2:-} in
      "") system_dns_menu ;;
      show) system_dns_show ;;
      *) usage; return 1 ;;
    esac
    return $?
  fi
  bootstrap || return 1
  case ${1:-} in
    # Opening the menu must not launch another Go runtime or rewrite services.
    "") if [[ ! -e $SB_BIN ]]; then need_core; fi
        ui_enter_fullscreen
        main_menu ;;
    add) if ((SB_NON_INTERACTIVE)); then add_node_cli; else add_node; fi ;;
    list|ls) list_nodes ;;
    info) select_node "${2:-}" && show_node "$SEL_ID" ;;
    edit) edit_node "${2:-}" ;;
    del|delete|rm) delete_node "${2:-}" ;;
    status) show_status ;;
    config) show_runtime_config ;;
    log|logs) show_log "${2:-}" ;;
    start|stop|restart) svc_cmd "$1" ;;
    route) case ${2:-} in "") routing_menu ;; show) route_show ;; *) usage; return 1 ;; esac ;;
    cert) cert_menu ;;
    core) core_menu ;;
    update) update_script "${2:-}" ;;
    uninstall) uninstall_all ;;
    *) usage; return 1 ;;
  esac
}

add_usage() {
  cat <<'EOF'
用法: sb add --protocol 协议 [选项]
协议: reality | ws | hy2 | tuic | anytls | anytls-reality | ss
  --port PORT            监听端口（默认随机）
  --public-port PORT     对外端口（默认等于监听端口）
  --address HOST         连接地址（默认检测公网 IP）
  --sni DOMAIN           Reality 目标（省略则优选，检测失败退出）
  --uuid UUID            指定 UUID（默认生成）
  --password-file PATH   单行密码文件（默认生成）
  --method METHOD        SS 算法（默认 chacha20-ietf-poly1305）
  --cert self|manual     TLS 证书方式（默认 self）
  --domain DOMAIN        TLS 证书域名（self 默认 www.bing.com）
  --cert-file PATH       已有证书；manual 必填
  --key-file PATH        已有私钥；manual 必填
  --flow none|vision     Reality Flow（默认 vision）
  --multiplex            VLESS 多路复用（Reality 需 --flow none）
  --note TEXT            节点备注
  --firewall auto|skip   防火墙放行（默认 auto）
  --non-interactive|-n   显式无交互；提供参数即进入无交互模式
EOF
}
cli_port_valid() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
parse_add_cli() {
  CLI_PROTO='' CLI_PORT='' CLI_PPORT='' CLI_HOST='' CLI_SNI='' CLI_UUID=''
  CLI_PASS='' CLI_PASSWORD_FILE='' CLI_METHOD='' CLI_CERT='' CLI_DOMAIN=''
  CLI_CERT_FILE='' CLI_KEY_FILE='' CLI_FLOW='' CLI_MUX=0 CLI_NOTE='' CLI_FIREWALL=auto
  local option value extra
  local seen='|'
  while (($#)); do
    option=$1; shift
    case $option in
      --non-interactive|-n) continue ;;
      --multiplex) CLI_MUX=1; continue ;;
      --protocol|--port|--public-port|--address|--sni|--uuid|--password-file|--method|--cert|--domain|--cert-file|--key-file|--flow|--note|--firewall) ;;
      *) err "未知添加参数: $option"; return 1 ;;
    esac
    [[ $seen != *"|$option|"* ]] || { err "重复参数: $option"; return 1; }
    seen+="$option|"
    (($#)) && [[ -n $1 && $1 != --* ]] || { err "$option 缺少参数值"; return 1; }
    value=$1; shift
    case $option in
      --protocol) CLI_PROTO=$value ;; --port) CLI_PORT=$value ;;
      --public-port) CLI_PPORT=$value ;; --address) CLI_HOST=$value ;;
      --sni) CLI_SNI=$value ;; --uuid) CLI_UUID=$value ;;
      --password-file) CLI_PASSWORD_FILE=$value ;; --method) CLI_METHOD=$value ;;
      --cert) CLI_CERT=$value ;; --domain) CLI_DOMAIN=$value ;;
      --cert-file) CLI_CERT_FILE=$value ;; --key-file) CLI_KEY_FILE=$value ;;
      --flow) CLI_FLOW=$value ;; --note) CLI_NOTE=$value ;; --firewall) CLI_FIREWALL=$value ;;
    esac
  done
  case $CLI_PROTO in hysteria2) CLI_PROTO=hy2 ;; shadowsocks) CLI_PROTO=ss ;; esac
  case $CLI_PROTO in reality|ws|hy2|tuic|anytls|anytls-reality|ss) ;; *) err '必须指定有效的 --protocol，参见 sb add --help'; return 1 ;; esac
  for value in "$CLI_PORT" "$CLI_PPORT"; do
    [[ -z $value ]] || cli_port_valid "$value" || { err "无效端口: $value"; return 1; }
  done
  if [[ -n $CLI_HOST ]]; then
    sni_valid_domain "$CLI_HOST" || system_dns_valid_ip "$CLI_HOST" || { err '连接地址应为 IP 或域名'; return 1; }
  fi
  for value in "$CLI_SNI" "$CLI_DOMAIN"; do
    [[ -z $value ]] || sni_valid_domain "$value" || { err "无效域名: $value"; return 1; }
  done
  [[ -z $CLI_UUID || $CLI_UUID =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || { err 'UUID 格式错误'; return 1; }
  case $CLI_FIREWALL in auto|skip) ;; *) err '--firewall 仅支持 auto 或 skip'; return 1 ;; esac
  case $CLI_PROTO in
    reality|anytls-reality|ss)
      [[ -z $CLI_CERT$CLI_DOMAIN$CLI_CERT_FILE$CLI_KEY_FILE ]] || { err '此协议不接受证书参数'; return 1; } ;;
    *)
      [[ -z $CLI_SNI ]] || { err 'TLS 证书协议请使用 --domain'; return 1; }
      CLI_CERT=${CLI_CERT:-self}
      case $CLI_CERT in
        self)
          [[ -z $CLI_CERT_FILE$CLI_KEY_FILE ]] || { err '证书文件需要 --cert manual'; return 1; }
          CLI_DOMAIN=${CLI_DOMAIN:-www.bing.com} ;;
        manual)
          [[ -n $CLI_DOMAIN && -f $CLI_CERT_FILE && -r $CLI_CERT_FILE && -f $CLI_KEY_FILE && -r $CLI_KEY_FILE ]] || { err 'manual 需要域名及可读的证书、私钥文件'; return 1; }
          [[ $CLI_CERT_FILE == /* ]] || CLI_CERT_FILE="$PWD/$CLI_CERT_FILE"
          [[ $CLI_KEY_FILE == /* ]] || CLI_KEY_FILE="$PWD/$CLI_KEY_FILE" ;;
        *) err '无交互证书方式仅支持 self 或 manual'; return 1 ;;
      esac ;;
  esac
  [[ $CLI_PROTO != ss || -z $CLI_SNI ]] || { err 'SS 不接受 --sni'; return 1; }
  [[ $CLI_PROTO == reality || -z $CLI_FLOW ]] || { err '--flow 仅适用于 reality'; return 1; }
  if [[ $CLI_PROTO == reality ]]; then
    CLI_FLOW=${CLI_FLOW:-vision}
    case $CLI_FLOW in none|vision) ;; *) err '--flow 仅支持 none 或 vision'; return 1 ;; esac
  fi
  if ((CLI_MUX)); then
    [[ $CLI_PROTO == reality || $CLI_PROTO == ws ]] && [[ $CLI_FLOW != vision ]] || { err 'multiplex 仅支持 VLESS，且不能与 Flow 同开'; return 1; }
  fi
  if [[ $CLI_PROTO == ss ]]; then
    CLI_METHOD=${CLI_METHOD:-chacha20-ietf-poly1305}
    case $CLI_METHOD in chacha20-ietf-poly1305|aes-128-gcm|aes-256-gcm|2022-blake3-aes-128-gcm) ;; *) err '不支持的 SS 算法'; return 1 ;; esac
  else
    [[ -z $CLI_METHOD ]] || { err '--method 仅适用于 SS'; return 1; }
  fi
  case $CLI_PROTO in reality|ws|tuic) ;; *) [[ -z $CLI_UUID ]] || { err '此协议不使用 UUID'; return 1; } ;; esac
  if [[ -n $CLI_PASSWORD_FILE ]]; then
    case $CLI_PROTO in reality|ws) err '此协议不使用密码'; return 1 ;; esac
    [[ -f $CLI_PASSWORD_FILE && -r $CLI_PASSWORD_FILE ]] || { err '密码文件不可读'; return 1; }
    # Read data literally, accepting one final newline but no additional lines.
    {
      IFS= read -r CLI_PASS || [[ -n $CLI_PASS ]]
      extra=''; if IFS= read -r extra || [[ -n $extra ]]; then
        err '密码文件必须只有一行'; return 1
      fi
    } < "$CLI_PASSWORD_FILE"
    [[ -n $CLI_PASS && $CLI_PASS != *$'\r'* ]] || { err '密码文件必须包含非空单行密码'; return 1; }
    if [[ $CLI_PROTO == ss ]]; then
      local N_METHOD=$CLI_METHOD N_PASS=$CLI_PASS
      validate_ss || return 1
    fi
  fi
}

add_node_cli() {
  if ! core_version >/dev/null; then
    [[ ! -e $SB_BIN ]] || { err '现有内核无法执行，停止添加'; return 1; }
    install_core || return 1
  fi
  node_change add_node_cli_impl
}
add_node_cli_impl() {
  local results count latency domain state
  meta_reset
  N_ID=$(next_id); N_CREATED=$(date '+%F %T'); N_PROTO=$CLI_PROTO
  if [[ $N_PROTO == anytls || $N_PROTO == anytls-reality ]]; then
    version_ge "$(core_version)" 1.12.0 || { err 'AnyTLS 需要 sing-box 1.12.0+'; return 1; }
  fi
  N_LPORT=$CLI_PORT
  [[ -n $N_LPORT ]] || N_LPORT=$(rand_port "$(proto_net)") || return 1
  if port_in_use "$N_LPORT" "$(proto_net)" || node_port_used "$N_LPORT"; then
    err "端口 $N_LPORT 已被占用"; return 1
  fi
  N_PPORT=${CLI_PPORT:-$N_LPORT}; N_HOST=$CLI_HOST
  [[ -n $N_HOST ]] || N_HOST=$(detect_ip)
  [[ -n $N_HOST ]] || { err '无法获取公网地址，请指定 --address'; return 1; }
  N_NOTE=${CLI_NOTE:-$(proto_label)-$N_ID}; N_MUX=$CLI_MUX
  N_UUID=$CLI_UUID; N_PASS=$CLI_PASS
  case $N_PROTO in reality|ws|tuic) [[ -n $N_UUID ]] || N_UUID=$(gen_uuid) || return 1 ;; esac
  case $N_PROTO in hy2|tuic|anytls|anytls-reality) [[ -n $N_PASS ]] || N_PASS=$(rand_str 24) || return 1 ;; esac
  if uses_reality; then
    N_SNI=$CLI_SNI
    if [[ -z $N_SNI ]]; then
      results=$(sni_scan) || return 1
      while IFS=$'\t' read -r count latency domain state; do
        if [[ $count == 3 ]]; then N_SNI=$domain; break; fi
      done <<< "$results"
      [[ -n $N_SNI ]] || { err '没有通过全部检测的 SNI，请指定 --sni'; return 1; }
    fi
    generate_reality_keys || return 1
    [[ $CLI_FLOW != vision ]] || N_FLOW=xtls-rprx-vision
  fi
  if [[ $N_PROTO == ss ]]; then
    N_METHOD=$CLI_METHOD
    [[ -n $N_PASS ]] || generate_ss_password || return 1
  fi
  [[ $N_PROTO != ws ]] || N_WSPATH="/$(rand_str 8)"
  snapshot || return 1
  if [[ -n $CLI_CERT ]]; then
    N_DOMAIN=$CLI_DOMAIN
    if [[ $CLI_CERT == self ]]; then cert_self || return 1
    else
      cert_manual_validate "$CLI_CERT_FILE" "$CLI_KEY_FILE" "$N_DOMAIN" || return 1
      N_CERTMODE=manual N_CERT=$CLI_CERT_FILE N_KEY=$CLI_KEY_FILE N_INSECURE=0
    fi
  fi
  NODE_FILES_CHANGED=1
  meta_save && write_node_conf || return 1
  [[ $CLI_FIREWALL == skip ]] || fw_open "$N_LPORT" "$(proto_net)" || return 1
  apply_config || return 1
  NODE_CHANGE_COMMITTED=1
  info '节点已添加并生效'
  show_node "$N_ID"
}
