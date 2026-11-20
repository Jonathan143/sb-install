#!/usr/bin/env bash
BBR_CONF=/etc/sysctl.d/99-sb-bbr.conf

bbr_require_linux() {
  [[ $(uname -s) == Linux ]] || { err 'BBR + fq 需要 Linux 内核'; return 1; }
  command -v sysctl >/dev/null || { err '缺少 sysctl，请安装 procps 或启用 BusyBox sysctl'; return 1; }
}

bbr_show() {
  local cc qdisc queues
  bbr_require_linux || return 1
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || cc='无法读取'
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null) || qdisc='无法读取'
  ui_title 'BBR + fq 状态'
  if [[ $cc == bbr && $qdisc == fq ]]; then echo '  系统默认 BBR + fq：已开启'
  elif [[ $cc == 无法读取 || $qdisc == 无法读取 ]]; then echo '  系统默认 BBR + fq：无法确认'
  else echo '  系统默认 BBR + fq：未全部开启'; fi
  printf '  TCP 默认拥塞控制：%s\n  默认队列：%s\n' "$cc" "$qdisc"
  printf '  内核可用算法：%s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo 无法读取)"
  printf '  非特权进程允许的算法：%s\n' "$(sysctl -n net.ipv4.tcp_allowed_congestion_control 2>/dev/null || echo 无法读取)"
  ui_section '网卡实际队列'
  if command -v tc >/dev/null && queues=$(tc qdisc show) && [[ -n $queues ]]; then
    printf '%s\n' "$queues"
  else
    echo '  无法读取网卡队列，请检查 tc（iproute2）及网络命名空间权限。'
  fi
}

bbr_enable() (
  bbr_require_linux || return 1
  local cc_key=net.ipv4.tcp_congestion_control fq_key=net.core.default_qdisc
  local old_cc old_fq tmp='' undo_cc=0 undo_fq=0
  old_cc=$(sysctl -n "$cc_key") && old_fq=$(sysctl -n "$fq_key") || {
    err '无法读取当前内核参数，请检查内核支持和容器权限'; return 1
  }
  mkdir -p "${BBR_CONF%/*}" || return 1
  [[ ! -e $BBR_CONF || -f $BBR_CONF ]] && [[ ! -L $BBR_CONF ]] || {
    err "配置目标不是普通文件：$BBR_CONF"; return 1
  }
  tmp=$(mktemp "${BBR_CONF}.XXXXXX") || return 1
  bbr_cleanup() {
    # Renaming the staged file commits both settings.
    [[ -e $tmp ]] || return 0
    if ((undo_cc)) && [[ $(sysctl -n "$cc_key") == bbr ]]; then sysctl -w "$cc_key=$old_cc" >/dev/null || err "恢复 $cc_key 失败"; fi
    if ((undo_fq)) && [[ $(sysctl -n "$fq_key") == fq ]]; then sysctl -w "$fq_key=$old_fq" >/dev/null || err "恢复 $fq_key 失败"; fi
    rm -f "$tmp"
  }
  trap bbr_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  printf '%s\n' "$fq_key=fq" "$cc_key=bbr" > "$tmp" && chmod 644 "$tmp" || return 1

  if [[ $old_fq != fq ]]; then
    if command -v modprobe >/dev/null; then modprobe sch_fq 2>/dev/null || :; fi
    undo_fq=1
    sysctl -w "$fq_key=fq" >/dev/null || { err '设置 fq 失败，请检查内核 sch_fq 支持及写入权限'; return 1; }
  fi
  if [[ $old_cc != bbr ]]; then
    if command -v modprobe >/dev/null; then modprobe tcp_bbr 2>/dev/null || :; fi
    undo_cc=1
    sysctl -w "$cc_key=bbr" >/dev/null || { err '设置 BBR 失败，请检查内核 tcp_bbr 支持及写入权限'; return 1; }
  fi
  [[ $(sysctl -n "$cc_key") == bbr && $(sysctl -n "$fq_key") == fq ]] || {
    err '内核参数回读校验失败'; return 1
  }
  mv -f "$tmp" "$BBR_CONF" || return 1
  undo_cc=0 undo_fq=0
  info "系统默认 BBR + fq 已开启，启动配置已保存到 $BBR_CONF"
  info '新建 TCP 连接和队列使用新默认值；当前网卡队列可用 sb bbr show 查看。'
)

bbr_menu() {
  local choice
  bbr_show || return 1
  ui_item 1 '一键开启系统默认 BBR + fq'
  ui_item 0 '返回'
  choice=$(ask_choice '请选择' 1) || return 0
  ui_clear_screen
  case $choice in
    1) bbr_enable ;;
    0) UI_SKIP_PAUSE=1 ;;
  esac
}
