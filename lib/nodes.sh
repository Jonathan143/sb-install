#!/usr/bin/env bash
# Source module; loaded by sb.sh.
#---------------------------------------------------------------------
# 节点操作
#---------------------------------------------------------------------
select_node() { # [id] -> SEL_ID
  local id=${1:-}
  if [[ -z $id ]]; then
    [[ -n $(list_ids) ]] || { info "暂无节点"; return 1; }
    list_nodes
    id=$(ask "请输入节点编号（0 返回）") || return 1
    [[ $id != 0 && $id != q && $id != Q ]] || { UI_SKIP_PAUSE=1; return 1; }
  fi
  [[ $id =~ ^[0-9]+$ && -f $META_DIR/$id.env ]] || { err "节点 $id 不存在"; return 1; }
  SEL_ID=$id
}

list_nodes() {
  local RED GREEN YELLOW CYAN PLAIN BOLD DIM
  ui_colors 1
  local id st
  [[ -n $(list_ids) ]] || { echo "暂无节点"; return 0; }
  printf '%-5s %-15s %-8s %-8s %-26s %-8s %s\n' 编号 协议 监听 对外 地址 状态 备注
  for id in $(list_ids); do
    meta_load "$id" || continue
    if port_listening "$N_LPORT" "$(proto_net)"; then st="${GREEN}运行${PLAIN}"; else st="${RED}未完整监听${PLAIN}"; fi
    printf '%-5s %-15s %-8s %-8s %-26s %b   %s\n' "$N_ID" "$(proto_label)" "$N_LPORT" "$N_PPORT" "$N_HOST" "$st" "$N_NOTE"
  done
}

add_node() { node_change add_node_impl "$@"; }
add_node_impl() {
  local p def_host cdn added_id
  need_core || return 1
  ui_title "新增节点 · 选择协议"
  ui_item 1 "VLESS + Reality"
  ui_item 2 "VLESS + WS + TLS"
  ui_item 3 "Hysteria2"
  ui_item 4 "TUIC v5"
  ui_item 5 "AnyTLS"
  ui_item 6 "AnyTLS + REALITY（Mihomo 不支持）"
  ui_item 7 "Shadowsocks"
  ui_item 0 "返回"
  p=$(ask_choice "请选择" 7 1) || return 1
  [[ $p != 0 ]] || { UI_SKIP_PAUSE=1; return 0; }
  meta_reset
  N_ID=$(next_id); N_CREATED=$(date '+%F %T')
  added_id=$N_ID
  case $p in
    1) N_PROTO=reality ;; 2) N_PROTO=ws ;; 3) N_PROTO=hy2 ;; 4) N_PROTO=tuic ;; 5) N_PROTO=anytls ;;
    6) N_PROTO=anytls-reality ;; 7) N_PROTO=ss ;;
    *) err "无效选择"; return 1 ;;
  esac
  if [[ $N_PROTO == anytls || $N_PROTO == anytls-reality ]] && ! version_ge "$(core_version)" 1.12.0; then
    warn "AnyTLS 需要 sing-box 1.12.0 及以上，当前为 $(core_version)"
    confirm "现在更新内核?" y && activate_core || return 1
    version_ge "$(core_version)" 1.12.0 || { err "更新后内核仍不支持 AnyTLS"; return 1; }
  fi

  pick_port "$(proto_net)" "" "" || return 1; N_LPORT=$PICKED
  N_PPORT=$(ask_pub_port "$N_LPORT") || return 1
  snapshot || return 1

  case $N_PROTO in
    reality|anytls-reality)
      generate_reality_keys || return 1
      if [[ $N_PROTO == reality ]]; then
        N_UUID=$(gen_uuid)
        if confirm "启用 Flow (xtls-rprx-vision)？（不能与 multiplex 同时使用，客户端需支持）" y; then
          N_FLOW=xtls-rprx-vision
        fi
      else
        N_PASS=$(rand_str 24)
        info "AnyTLS + REALITY 不支持 Clash Verge Rev / Mihomo，请使用支持此组合的客户端。"
      fi
      pick_sni || return 1; N_SNI=$PICKED
      def_host=$(detect_ip) ;;
    ss)
      pick_ss_method || return 1
      generate_ss_password || return 1
      def_host=$(detect_ip) ;;
    ws|hy2|tuic|anytls)
      case $N_PROTO in
        ws) N_UUID=$(gen_uuid); N_WSPATH="/$(rand_str 8)" ;;
        hy2) N_PASS=$(rand_str 16)
             confirm "启用 salamander 混淆？" n && N_OBFS=$(rand_str 16) ;;
        tuic) N_UUID=$(gen_uuid); N_PASS=$(rand_str 16) ;;
        anytls) N_PASS=$(rand_str 16) ;;
      esac
      cert_flow || { err "证书配置失败，已取消"; return 1; }
      if [[ $N_CERTMODE == self ]]; then def_host=$(detect_ip); else def_host=$N_DOMAIN; fi
      if [[ $N_PROTO == ws ]]; then
        cdn=" 443 2053 2083 2087 2096 8443 "
        [[ $cdn != *" $N_PPORT "* ]] && info "提示: 若要经 Cloudflare CDN，对外端口需为 443/2053/2083/2087/2096/8443"
      fi ;;
  esac
  if multiplex_supported && [[ -z $N_FLOW ]]; then
    if confirm "启用 multiplex 多路复用？（客户端需支持 sing-mux 并启用 padding）" n; then
      toggle_multiplex || return 1
    fi
  fi
  if [[ $N_PROTO == hy2 ]]; then pick_hy2_hop || return 1; fi
  case $(proto_net) in
    udp) info "提示: $(proto_label) 使用 UDP，NAT 机器请确认商家已映射 UDP 端口" ;;
    both) info "提示: Shadowsocks 使用 TCP + UDP，NAT 机器请将两种协议映射到相同对外端口" ;;
  esac

  N_HOST=$(ask "客户端连接地址（IP 或域名）" "$def_host") || return 1
  [[ -z $N_HOST ]] && { err "地址不能为空"; return 1; }
  N_NOTE=$(ask "节点备注" "$(proto_label)-$N_ID") || return 1

  NODE_FILES_CHANGED=1
  meta_save || return 1
  write_node_conf || { err "生成配置失败"; restore_snapshot; return 1; }
  fw_open "$N_LPORT" "$(proto_net)"
  if apply_config; then
    info "节点已添加并生效"
    show_node "$added_id"
  else
    fw_close "$N_LPORT" "$(proto_net)"
    return 1
  fi
}

edit_node() { node_change edit_node_impl "$@"; }
edit_node_impl() {
  local old_l old_net c v new_l
  select_node "${1:-}" || return 1
  meta_load "$SEL_ID" || return 1
  old_l=$N_LPORT; old_net=$(proto_net)
  ui_title "修改节点 [$N_ID] $(proto_label) $N_NOTE"
  ui_item 1 "端口（监听 / 对外）"
  if uses_reality; then ui_item 2 "SNI"
  elif [[ $N_PROTO == ss ]]; then ui_item 2 "加密方式（同时生成新密码/密钥）"
  else ui_item 2 "域名与证书"; fi
  [[ $N_PROTO != reality ]] || ui_item 3 "Reality Flow 开关"
  ui_item 4 "重新生成 UUID / 密码 / 密钥"
  ui_item 5 "客户端连接地址"
  ui_item 6 "备注"
  [[ $N_PROTO != hy2 ]] || ui_item 7 "Hysteria2 混淆开关"
  if multiplex_supported; then ui_item 8 "Multiplex 多路复用开关（VLESS）"; fi
  [[ $N_PROTO != hy2 ]] || ui_item 9 "Hysteria2 端口跳跃（商家转发）"
  ui_item 0 "返回"
  c=$(ask_choice "请选择" 9) || return 1
  [[ $c != 0 ]] || { UI_SKIP_PAUSE=1; return 0; }
  snapshot || return 1
  case $c in
    1) pick_port "$(proto_net)" "$N_ID" "$old_l" || return 1; N_LPORT=$PICKED
       N_PPORT=$(ask_pub_port "$N_PPORT") || return 1 ;;
    2) if uses_reality; then pick_sni || return 1; N_SNI=$PICKED
       elif [[ $N_PROTO == ss ]]; then pick_ss_method || return 1; generate_ss_password || return 1
       else cert_flow || return 1; fi ;;
    3) toggle_reality_flow || return 1 ;;
    4) case $N_PROTO in
         reality) N_UUID=$(gen_uuid); generate_reality_keys || return 1 ;;
         anytls-reality) N_PASS=$(rand_str 24); generate_reality_keys || return 1 ;;
         ss) generate_ss_password || return 1 ;;
         ws) N_UUID=$(gen_uuid) ;;
         tuic) N_UUID=$(gen_uuid); N_PASS=$(rand_str 16) ;;
         hy2|anytls) N_PASS=$(rand_str 16); [[ -n $N_OBFS ]] && N_OBFS=$(rand_str 16) ;;
       esac ;;
    5) N_HOST=$(ask "客户端连接地址" "$N_HOST") || return 1 ;;
    6) N_NOTE=$(ask "备注" "$N_NOTE") || return 1 ;;
    7) [[ $N_PROTO == hy2 ]] || { warn "仅 Hysteria2 支持"; return 1; }
       if [[ -n $N_OBFS ]]; then N_OBFS=""; info "混淆已关闭"; else N_OBFS=$(rand_str 16); info "混淆已开启"; fi ;;
    8) toggle_multiplex || return 1 ;;
    9) pick_hy2_hop || return 1 ;;
    *) err "无效选择"; return 1 ;;
  esac
  NODE_FILES_CHANGED=1
  meta_save || return 1
  write_node_conf || { restore_snapshot; return 1; }
  new_l=$N_LPORT
  if [[ $new_l != "$old_l" ]]; then fw_open "$new_l" "$old_net"; fi
  if apply_config; then
    if [[ $new_l != "$old_l" ]]; then fw_close "$old_l" "$old_net"; fi
    info "修改已生效"; show_node "$SEL_ID"
  else
    if [[ $new_l != "$old_l" ]]; then fw_close "$new_l" "$old_net"; fi
    err "修改未生效"; return 1
  fi
}

delete_node() { node_change delete_node_impl "$@"; }
delete_node_impl() {
  local id other
  select_node "${1:-}" || return 1
  id=$SEL_ID
  meta_load "$id" || return 1
  confirm "确认删除节点 [$id] $(proto_label) $N_NOTE ?" n || return 0
  snapshot || return 1
  local dom=$N_DOMAIN mode=$N_CERTMODE port=$N_LPORT net; net=$(proto_net)
  NODE_FILES_CHANGED=1
  rm -f "$(conf_file)" "$META_DIR/$id.env" || return 1
  if [[ -z $(list_ids) && ! ( ${SB_MODE:-takeover} == coexist && -f $SB_DIR/config.json ) ]]; then
    svc stop >/dev/null 2>&1 || { err "服务停止失败，已取消删除"; return 1; }
    write_nodes_txt || return 1
    info "已无任何节点，sing-box 服务已停止"
  else
    apply_config || return 1
  fi
  fw_close "$port" "$net"
  info "节点 $id 已删除"
  # 证书清理：该域名不再被其它节点使用时询问
  if [[ -n $dom && $mode != builtin && $mode != manual ]]; then
    other=0
    for i in $(list_ids); do meta_load "$i" && [[ $N_DOMAIN == "$dom" ]] && other=1; done
    if ((other == 0)) && [[ -d $CERT_DIR/$dom ]]; then
      if confirm "域名 $dom 的证书已无节点使用，是否删除证书文件? （保留可避免再次申请触发频率限制）" n; then
        [[ $mode == dns && -x $ACME_SH ]] && "$ACME_SH" --remove -d "$dom" --ecc >/dev/null 2>&1
        rm -rf "${CERT_DIR:?}/$dom"; info "证书已删除"
      fi
    fi
  fi
}
