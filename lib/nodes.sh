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
    [[ $id != 0 && $id != q ]] || return 1
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
    if port_in_use "$N_LPORT" "$(proto_net)"; then st="${GREEN}运行${PLAIN}"; else st="${RED}未监听${PLAIN}"; fi
    printf '%-5s %-15s %-8s %-8s %-26s %b   %s\n' "$N_ID" "$(proto_label)" "$N_LPORT" "$N_PPORT" "$N_HOST" "$st" "$N_NOTE"
  done
}

add_node() {
  local p def_host cdn
  need_core || return 1
  ui_title "新增节点 · 选择协议"
  ui_item 1 "VLESS + Reality"
  ui_item 2 "VLESS + WS + TLS"
  ui_item 3 "Hysteria2"
  ui_item 4 "TUIC v5"
  ui_item 5 "AnyTLS"
  ui_item 0 "返回"
  p=$(ask_choice "请选择" 5 1) || return 1
  [[ $p != 0 ]] || return 0
  meta_reset
  N_ID=$(next_id); N_CREATED=$(date '+%F %T')
  case $p in
    1) N_PROTO=reality ;; 2) N_PROTO=ws ;; 3) N_PROTO=hy2 ;; 4) N_PROTO=tuic ;; 5) N_PROTO=anytls ;;
    *) err "无效选择"; return 1 ;;
  esac
  if [[ $N_PROTO == anytls ]] && ! version_ge "$(core_version)" 1.12.0; then
    warn "AnyTLS 需要 sing-box 1.12.0 及以上，当前为 $(core_version)"
    confirm "现在更新内核?" y && install_core || return 1
  fi

  pick_port "$(proto_net)" "" "" || return 1; N_LPORT=$PICKED
  N_PPORT=$(ask_pub_port "$N_LPORT") || return 1

  case $N_PROTO in
    reality)
      N_UUID=$(gen_uuid); N_SID=$(openssl rand -hex 8)
      local keys; keys=$("$SB_BIN" generate reality-keypair) || { err "生成密钥失败"; return 1; }
      N_PRIV=$(awk '/PrivateKey/{print $2}' <<<"$keys"); N_PBK=$(awk '/PublicKey/{print $2}' <<<"$keys")
      if confirm "启用 Flow (xtls-rprx-vision)？（不能与 multiplex 同时使用，客户端需支持）" y; then
        N_FLOW=xtls-rprx-vision
      fi
      pick_sni || return 1; N_SNI=$PICKED
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
  [[ $(proto_net) == udp ]] && info "提示: $(proto_label) 使用 UDP，NAT 机器请确认商家已映射 UDP 端口"

  N_HOST=$(ask "客户端连接地址（IP 或域名）" "$def_host") || return 1
  [[ -z $N_HOST ]] && { err "地址不能为空"; return 1; }
  N_NOTE=$(ask "节点备注" "$(proto_label)-$N_ID") || return 1

  snapshot
  meta_save
  write_node_conf || { err "生成配置失败"; restore_snapshot; return 1; }
  fw_open "$N_LPORT" "$(proto_net)"
  if apply_config; then
    info "节点已添加并生效"
    show_node "$N_ID"
  else
    meta_load "$N_ID" 2>/dev/null || true
    fw_close "$N_LPORT" "$(proto_net)"
    return 1
  fi
}

edit_node() {
  local old_l old_net c v keys
  select_node "${1:-}" || return 1
  meta_load "$SEL_ID"
  old_l=$N_LPORT; old_net=$(proto_net)
  ui_title "修改节点 [$N_ID] $(proto_label) $N_NOTE"
  ui_item 1 "端口（监听 / 对外）"
  ui_item 2 "$([[ $N_PROTO == reality ]] && echo 'SNI' || echo '域名与证书')"
  ui_item 3 "Reality Flow 开关"
  ui_item 4 "重新生成 UUID / 密码 / 密钥"
  ui_item 5 "客户端连接地址"
  ui_item 6 "备注"
  ui_item 7 "Hysteria2 混淆开关"
  ui_item 8 "Multiplex 多路复用开关（VLESS）"
  ui_item 0 "返回"
  c=$(ask_choice "请选择" 8) || return 1
  [[ $c != 0 ]] || return 0
  snapshot
  case $c in
    1) pick_port "$(proto_net)" "$N_ID" "$old_l" || return 1; N_LPORT=$PICKED
       N_PPORT=$(ask_pub_port "$N_PPORT") || return 1 ;;
    2) if [[ $N_PROTO == reality ]]; then pick_sni || return 1; N_SNI=$PICKED
       else cert_flow || return 1; fi ;;
    3) toggle_reality_flow || return 1 ;;
    4) case $N_PROTO in
         reality) N_UUID=$(gen_uuid); N_SID=$(openssl rand -hex 8)
                  keys=$("$SB_BIN" generate reality-keypair) || return 1
                  N_PRIV=$(awk '/PrivateKey/{print $2}' <<<"$keys"); N_PBK=$(awk '/PublicKey/{print $2}' <<<"$keys") ;;
         ws) N_UUID=$(gen_uuid) ;;
         tuic) N_UUID=$(gen_uuid); N_PASS=$(rand_str 16) ;;
         hy2|anytls) N_PASS=$(rand_str 16); [[ -n $N_OBFS ]] && N_OBFS=$(rand_str 16) ;;
       esac ;;
    5) N_HOST=$(ask "客户端连接地址" "$N_HOST") || return 1 ;;
    6) N_NOTE=$(ask "备注" "$N_NOTE") || return 1 ;;
    7) [[ $N_PROTO == hy2 ]] || { warn "仅 Hysteria2 支持"; return 1; }
       if [[ -n $N_OBFS ]]; then N_OBFS=""; info "混淆已关闭"; else N_OBFS=$(rand_str 16); info "混淆已开启"; fi ;;
    8) toggle_multiplex || return 1 ;;
    *) err "无效选择"; return 1 ;;
  esac
  meta_save
  write_node_conf || { restore_snapshot; return 1; }
  if [[ $N_LPORT != "$old_l" ]]; then fw_close "$old_l" "$old_net"; fw_open "$N_LPORT" "$old_net"; fi
  if apply_config; then info "修改已生效"; show_node "$SEL_ID"; else err "修改失败，已回滚"; return 1; fi
}

delete_node() {
  local id other
  select_node "${1:-}" || return 1
  id=$SEL_ID
  meta_load "$id"
  confirm "确认删除节点 [$id] $(proto_label) $N_NOTE ?" n || return 0
  snapshot
  local dom=$N_DOMAIN mode=$N_CERTMODE net; net=$(proto_net)
  fw_close "$N_LPORT" "$net"
  rm -f "$(conf_file)" "$META_DIR/$id.env"
  if [[ -z $(list_ids) ]]; then
    svc stop >/dev/null 2>&1; write_nodes_txt
    info "已无任何节点，sing-box 服务已停止"
  else
    apply_config || return 1
  fi
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
