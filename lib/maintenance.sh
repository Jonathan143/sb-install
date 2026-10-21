#!/usr/bin/env bash
# Source module; loaded by sb.sh.
#---------------------------------------------------------------------
# 证书管理 / 内核与脚本更新 / 卸载
#---------------------------------------------------------------------
cert_menu() {
  local d dom c rc=0
  ui_title "证书管理"
  echo "已保存的证书:"
  for d in "$CERT_DIR"/*/; do
    [[ -s ${d}fullchain.pem ]] || continue
    dom=$(basename "$d")
    printf '  %-32s 到期: %s%s\n' "$dom" "$(cert_expiry "${d}fullchain.pem")" "$([[ -e ${d}.selfsigned ]] && echo '  (自签)')"
  done
  echo
  echo "  1) 强制续期某个域名（acme.sh）   0) 返回"
  c=$(ask_choice "请选择" 1 0) || return 0
  [[ $c != 0 ]] || { UI_SKIP_PAUSE=1; return 0; }
  if [[ $c == 1 ]]; then
    if [[ -x $ACME_SH ]]; then
      dom=$(ask_domain "域名") || return 1
      "$ACME_SH" --renew -d "$dom" --ecc --force && info "续期完成（证书已自动部署并重启服务）"
      rc=$?
    else
      err "尚未安装 acme.sh"; rc=1
    fi
  else
    warn "无效选择"; rc=1
  fi
  [[ ${1:-} != pause ]] || pause
  return "$rc"
}

update_core() {
  local cur new
  cur=$(core_version); new=$(latest_version)
  echo "当前内核: ${cur:-未安装}    最新版本: ${new:-未知}"
  confirm "安装/更新到 ${new:-最新版}?" y || return 0
  [[ -x $SB_BIN ]] && cp -f "$SB_BIN" "$SB_BIN.bak"
  install_core "$new" || { [[ -f $SB_BIN.bak ]] && mv -f "$SB_BIN.bak" "$SB_BIN"; return 1; }
  sb_args
  if "$SB_BIN" "${SB_ARGS[@]}" check >/dev/null 2>&1; then
    write_service; svc restart >/dev/null 2>&1; info "内核已更新并重启"; rm -f "$SB_BIN.bak"
  else
    err "新内核与现有配置不兼容，已回退"; mv -f "$SB_BIN.bak" "$SB_BIN"
  fi
}

core_menu() {
  local c version
  ui_title '内核管理'
  ui_item 1 '安装 / 更新最新版'; ui_item 2 '安装指定版本'; ui_item 3 '查看当前版本'; ui_item 0 '返回'
  c=$(ask_choice "请选择" 3) || return 0
  case $c in
    1) update_core ;;
    2) version=$(ask "版本号（如 1.12.0）") || return 1
       [[ -n $version ]] || { warn "版本号不能为空"; return 1; }
       install_core "$version" && write_service ;;
    3) echo "$(core_version || echo 未安装)" ;;
  esac
}

restart_script() {
  local reply
  read -rp "按回车重新运行 sb..." reply || exit 0
  # Release the old process's lock before the new script acquires its own.
  exec 9>&-
  exec bash "$SB_CMD"
  err "重新运行失败，请手动运行 sb"
  exit 1
}

update_script() {
  local tmp new
  [[ -n $SCRIPT_URL ]] || { err "未设置 SCRIPT_URL，无法在线更新。可用 SCRIPT_URL=<直链> sb update 指定一次"; return 1; }
  tmp=$(mktemp)
  curl -fsSL "$SCRIPT_URL" -o "$tmp" || { err "下载失败"; rm -f "$tmp"; return 1; }
  bash -n "$tmp" || { err "下载的脚本语法有误，已取消"; rm -f "$tmp"; return 1; }
  if grep -q '^SB_SOURCE_DIR=' "$tmp"; then
    err "下载的是源码入口，缺少配套模块。请将 SCRIPT_URL 改为 Release 的 sb.sh 下载地址"
    rm -f "$tmp"; return 1
  fi
  new=$(sed -n 's/^SB_VERSION="\(.*\)"/\1/p' "$tmp" | head -n1)
  info "当前 v$SB_VERSION，远程 v${new:-?}"
  confirm "更新脚本?" y || { rm -f "$tmp"; return 0; }
  if ! install -m 755 "$tmp" "$SB_CMD.new" || ! mv -f "$SB_CMD.new" "$SB_CMD"; then
    rm -f "$tmp" "$SB_CMD.new"
    err "脚本安装失败，未重新运行"
    return 1
  fi
  rm -f "$tmp"
  save_conf
  if [[ ${1:-} == restart ]]; then
    info "脚本已更新"
    restart_script
  fi
  info "脚本已更新，请重新运行 sb"
}

uninstall_all() {
  local id
  confirm "确认卸载 sing-box 及 sb 命令?" n || return 0
  for id in $(list_ids); do meta_load "$id" && fw_close "$N_LPORT" "$(proto_net)"; done
  svc stop >/dev/null 2>&1; svc disable >/dev/null 2>&1
  rm -f /etc/systemd/system/$SB_SERVICE.service /etc/init.d/$SB_SERVICE "$SB_BIN" "$SB_BIN.bak"
  has_systemd && systemctl daemon-reload
  if ! confirm "保留配置与证书目录 $SB_DIR ?" y; then
    rm -rf "$SB_DIR" "$SB_WORKDIR"
    if [[ -x $ACME_SH ]] && confirm "同时卸载 acme.sh?" n; then "$ACME_SH" --uninstall >/dev/null 2>&1; rm -rf "$ACME_HOME"; fi
  fi
  rm -f "$SB_CMD"
  info "卸载完成"
}
