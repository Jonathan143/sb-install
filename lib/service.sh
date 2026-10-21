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

show_log() {
  if has_systemd; then
    if [[ ${1:-} == -f ]]; then journalctl -u "$SB_SERVICE" -f; else journalctl -u "$SB_SERVICE" -n 80 --no-pager; fi
  else
    if [[ ${1:-} == -f ]]; then tail -f /var/log/sing-box.log; else tail -n 80 /var/log/sing-box.log; fi
  fi
}

svc_cmd() { # start|stop|restart
  if [[ $1 != stop ]]; then
    sb_args
    "$SB_BIN" "${SB_ARGS[@]}" check || { err "配置校验未通过，已取消"; return 1; }
  fi
  svc "$1" && info "已执行: $1"
  sleep 1
  svc is-active && info "当前状态: 运行中" || info "当前状态: 未运行"
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
