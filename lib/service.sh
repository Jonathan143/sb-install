#!/usr/bin/env bash
# Source module; loaded by sb.sh.
#---------------------------------------------------------------------
# 状态 / 日志 / 服务
#---------------------------------------------------------------------
show_status() {
  local RED GREEN YELLOW CYAN PLAIN BOLD DIM
  ui_colors 1
  local pid id
  echo "内核: $(core_version || true)    脚本: v$SB_VERSION    配置模式: $SB_MODE"
  if svc is-active; then echo -e "服务状态: ${GREEN}运行中${PLAIN}"; else echo -e "服务状态: ${RED}未运行${PLAIN}"; fi
  if has_systemd; then
    echo "开机自启: $(systemctl is-enabled "$SB_SERVICE" 2>/dev/null)"
    pid=$(systemctl show -p MainPID --value "$SB_SERVICE" 2>/dev/null)
    if [[ -n $pid && $pid != 0 ]]; then
      echo "PID: $pid    内存: $(ps -o rss= -p "$pid" | awk '{printf "%.1f MB", $1/1024}')    启动于: $(systemctl show -p ActiveEnterTimestamp --value "$SB_SERVICE")"
    fi
  fi
  echo; list_nodes; echo
  for id in $(list_ids); do
    meta_load "$id" || continue
    if [[ $N_CERTMODE == builtin ]]; then
      echo "[$id] $N_DOMAIN 证书: sing-box 内置 ACME 自动管理"
    elif [[ -n $N_CERT && -r $N_CERT ]]; then
      echo "[$id] $N_DOMAIN 证书到期: $(cert_expiry "$N_CERT")"
    fi
  done
}

show_runtime_config() {
  local file arg path i result=0
  local SB_ARGS=() files=()
  ui_title 'sing-box 运行配置'
  if svc is-active; then
    printf '  服务：运行中\n'
  else
    printf '  服务：未运行（显示当前配置文件）\n'
  fi
  printf '  以下为服务配置文件的磁盘内容，未重启的修改可能尚未加载。\n'
  # Use the same source selection as the generated service. In takeover mode
  # an old config.json is intentionally excluded; coexist mode includes it.
  sb_args
  for ((i=0; i<${#SB_ARGS[@]}; i++)); do
    arg=${SB_ARGS[i]}
    case $arg in
      -c) i=$((i + 1)); files+=("${SB_ARGS[i]}") ;;
      -C)
        i=$((i + 1)); path=${SB_ARGS[i]}
        for file in "$path"/*.json; do
          [[ -f $file ]] && files+=("$file")
        done ;;
    esac
  done
  if ((${#files[@]} == 0)); then
    info '暂无配置文件'
    return 0
  fi
  for file in "${files[@]}"; do
    ui_section "$file"
    if ! jq . "$file"; then
      err "无法读取或解析配置文件: $file"
      result=1
    fi
  done
  return "$result"
}

show_log() {
  if has_systemd; then
    if [[ ${1:-} == -f ]]; then journalctl -u "$SB_SERVICE" -f; else journalctl -u "$SB_SERVICE" -n 80 --no-pager; fi
  else
    if [[ ${1:-} == -f ]]; then tail -f /var/log/sing-box.log; else tail -n 80 /var/log/sing-box.log; fi
  fi
}

svc_cmd() { # start|stop|restart
  local action=$1
  case $action in start|stop|restart) ;; *) err "无效服务操作: $action"; return 1 ;; esac
  if [[ $action != stop ]]; then
    sb_args
    "$SB_BIN" "${SB_ARGS[@]}" check || { err "配置校验未通过，已取消"; return 1; }
    # 与内核更新保持一致，修复缺失/过期的服务定义并创建工作目录。
    write_service || { err "服务定义更新失败，已取消"; return 1; }
  fi
  if ! svc "$action"; then
    err "服务操作失败: $action"
    show_log >&2
    return 1
  fi
  sleep 2
  if svc is-active; then
    if [[ $action == stop ]]; then
      err "停止后服务仍在运行"
      return 1
    fi
    info "当前状态: 运行中"
  else
    if [[ $action != stop ]]; then
      err "服务${action}后未正常运行，最近日志:"
      show_log >&2
      return 1
    fi
    info "当前状态: 未运行"
  fi
  info "已执行: $action"
}

service_menu() {
  local c
  ui_title '服务控制'
  ui_item 1 '启动'; ui_item 2 '停止'; ui_item 3 '重启'
  ui_item 4 '开启开机自启'; ui_item 5 '关闭开机自启'; ui_item 0 '返回'
  c=$(ask_choice "请选择" 5) || return 0
  case $c in
    0) UI_SKIP_PAUSE=1 ;;
    1) svc_cmd start ;; 2) svc_cmd stop ;; 3) svc_cmd restart ;;
    4) svc enable && info "已开启开机自启" ;; 5) svc disable && info "已关闭开机自启" ;;
  esac
}

readonly_require() {
  local tool failed=0
  for tool in "$@"; do
    command -v "$tool" >/dev/null || { err "缺少查询工具: $tool"; failed=1; }
  done
  return "$failed"
}
readonly_dispatch() {
  case $1 in
    status) readonly_require ss openssl && show_status ;;
    doctor) show_doctor ;;
    config) readonly_require jq && show_runtime_config ;;
    list|ls) readonly_require ss && list_nodes ;;
    info) readonly_require jq openssl && select_node "${2:-}" && show_node "$SEL_ID" ;;
    log|logs) show_log "${2:-}" ;;
  esac
}
show_doctor() {
  local failed=0 tool version id files=0
  local N_ID N_PROTO N_LPORT N_PPORT N_HOST N_DOMAIN N_SNI N_UUID N_PASS N_FLOW N_MUX
  local N_PRIV N_PBK N_SID N_WSPATH N_CERTMODE N_CERT N_KEY N_INSECURE N_ACMEV
  local N_OBFS N_HOP_PORTS N_HOP_INTERVAL N_METHOD N_NOTE N_CREATED
  printf 'sb v%s  配置模式: %s\n' "$SB_VERSION" "$SB_MODE"
  for tool in jq ss openssl; do
    if command -v "$tool" >/dev/null; then printf '[通过] 工具 %s\n' "$tool"
    else printf '[失败] 缺少工具 %s\n' "$tool"; failed=1; fi
  done
  if version=$(core_version); then
    printf '[通过] 内核可执行: %s\n' "$version"
    if [[ -d $CONF_DIR || ( $SB_MODE == coexist && -f $SB_DIR/config.json ) ]]; then
      sb_args
      if "$SB_BIN" "${SB_ARGS[@]}" check; then printf '[通过] 配置校验\n'
      else printf '[失败] 配置校验\n'; failed=1; fi
    else printf '[失败] 未找到配置目录\n'; failed=1; fi
  else printf '[失败] 内核缺失或无法执行: %s\n' "$SB_BIN"; failed=1; fi
  if has_systemd; then printf '[通过] 服务管理器: systemd\n'
  elif command -v rc-service >/dev/null && [[ -f /run/openrc/softlevel ]]; then
    printf '[通过] 服务管理器: OpenRC\n'
  else printf '[失败] 未检测到运行中的 systemd/OpenRC\n'; failed=1; fi
  if svc is-active; then printf '[通过] sing-box 服务运行中\n'
  else printf '[失败] sing-box 服务未运行\n'; failed=1; fi
  for id in $(list_ids); do
    meta_load "$id" || { printf '[失败] 节点 %s 元数据不可读\n' "$id"; failed=1; continue; }
    files=$((files + 1))
    if command -v ss >/dev/null; then
      if port_listening "$N_LPORT" "$(proto_net)"; then printf '[通过] 节点 %s 监听 %s/%s\n' "$id" "$N_LPORT" "$(proto_net)"
      else printf '[失败] 节点 %s 端口未完整监听\n' "$id"; failed=1; fi
    fi
    if [[ $N_CERTMODE == builtin ]]; then
      printf '[信息] 节点 %s 证书由内核 ACME 管理\n' "$id"
    elif [[ -n $N_CERT ]] && command -v openssl >/dev/null; then
      if cert_manual_validate "$N_CERT" "$N_KEY" "$N_DOMAIN"; then
        printf '[通过] 节点 %s 证书到期: %s\n' "$id" "$(cert_expiry "$N_CERT")"
        if ! cert_valid "$N_CERT"; then printf '[失败] 节点 %s 证书将在 30 天内到期\n' "$id"; failed=1; fi
      else printf '[失败] 节点 %s 证书检查\n' "$id"; failed=1; fi
    fi
  done
  printf '已检查 %s 个托管节点\n' "$files"
  return "$failed"
}
