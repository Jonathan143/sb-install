#!/usr/bin/env bash
# Source module; loaded by sb.sh.
#---------------------------------------------------------------------
# 主菜单 / 入口
#---------------------------------------------------------------------
usage() {
  cat <<EOF
sb v$SB_VERSION - sing-box 节点管理
用法: sb [命令]
  (无)            打开交互菜单
  add [选项]      新增节点（参数模式见 sb add --help）
  list            列出节点
  info [编号]     查看节点链接/二维码/客户端配置
  edit [编号]     修改节点
  del [编号]      删除节点
  status          运行状态、证书到期时间
  doctor          只读检查内核、配置、服务、监听及证书
  config          查看 sing-box 运行配置文件
  log [-f]        查看日志（-f 实时）
  start|stop|restart   服务控制
  dns [show]      系统 DNS 配置 / 查看
  bbr [show|enable]  BBR + fq 状态 / 一键开启
  route [show]    出口与分流 / 查看规则
  cert            证书管理
  core            安装/更新 sing-box 内核
  update [--beta] 更新 sb 脚本（--beta 获取最新测试版）
  uninstall       卸载
EOF
}

print_main_menu() {
  local RED GREEN YELLOW CYAN PLAIN BOLD DIM st core_label node_count file
  ui_colors 1
  if svc is-active; then st="${GREEN}运行中${PLAIN}"; else st="${RED}未运行${PLAIN}"; fi
  ui_title "sing-box 管理脚本 v$SB_VERSION"
  core_label='未安装'
  if [[ -x $SB_BIN ]]; then core_label='已安装（未检测版本）'
  elif [[ -e $SB_BIN ]]; then core_label='文件不可执行'; fi
  node_count=0
  for file in "$META_DIR"/*.env; do
    [[ -f $file ]] && node_count=$((node_count + 1))
  done
  printf '  服务 %s  ·  内核 %s  ·  节点 %s\n' "$st" "$core_label" "$node_count"
  ui_section '节点管理'
  ui_item 1 '新增节点'; ui_item 2 '查看节点 / 分享配置'
  ui_item 3 '修改节点'; ui_item 4 '删除节点'
  ui_item 5 'SNI 优选测试'
  ui_section '运行与维护'
  ui_item 6 '运行状态'; ui_item 7 '查看运行配置'
  ui_item 8 '查看日志'; ui_item 9 '服务控制'
  ui_item 10 '出口与分流'; ui_item 11 '系统 DNS 配置'
  ui_item 12 '证书管理'; ui_item 13 'BBR + fq 拥塞控制'
  ui_item 14 '更新内核 / 脚本'; ui_item 15 '卸载'
  ui_item 0 '退出（也可输入 q）'
}

# Called in a command substitution. The alternate screen and its cleanup
# belong only to the menu prompt, including EOF and interrupted reads.
main_menu_choice() {
  local rows cols
  if [[ -t 0 && -t 2 && -t 3 && ${TERM:-dumb} != dumb ]]; then
    trap 'printf "\033[?1049l" >&3' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    printf '\033[?1049h\033[2J\033[H' >&3
    # The full menu occupies 23 lines plus the prompt at normal widths.
    if read -r rows cols < <(stty size) && ((rows > 0 && cols > 0 && (rows < 24 || cols < 54))); then
      small_menu_choice "$rows" "$cols"
      return
    fi
  fi
  print_main_menu >&3
  ask_choice "请选择" 15
}

# A short or narrow alternate screen has no native scrollback. Allow a
# selection on every page, including numbers listed on another page.
small_menu_choice() {
  local rows=$1 cols=$2 line choice start=0 index used height
  local lines=()
  while IFS= read -r line; do lines+=("$line"); done < <(print_main_menu)
  while true; do
    printf '\033[2J\033[H' >&3
    used=0
    for ((index=start; index<${#lines[@]}; index++)); do
      line=${lines[index]}
      # Allow two cells per character for Chinese labels and one for empty lines.
      height=$(( (2 * ${#line} + cols - 1) / cols ))
      ((height > 0)) || height=1
      ((index == start || used + height < rows - 1)) || break
      printf '%s\n' "$line" >&3
      used=$((used + height))
    done
    if ((start == 0 && index == ${#lines[@]})); then ask_choice '请选择' 15; return; fi
    choice=$(ask_choice '请选择，回车翻页' 15 n) || return 1
    if [[ $choice != n ]]; then printf '%s\n' "$choice"; return; fi
    start=$((index % ${#lines[@]}))
  done
}

main_menu() {
  local c installed line UI_SKIP_PAUSE=0
  while true; do
    installed=""
    if [[ -r $SB_CMD ]]; then
      while IFS= read -r line; do
        if [[ $line == SB_VERSION=\"*\" ]]; then
          installed=${line#SB_VERSION=\"}; installed=${installed%\"}
          break
        fi
      done < "$SB_CMD"
    fi
    if [[ -n $installed && $installed != "$SB_VERSION" ]]; then
      info "当前运行 v${SB_VERSION}，磁盘已安装 v${installed}，需要重新加载脚本"
      restart_script
    fi
    # Keep the selected number on stdout and draw on the original output.
    { c=$(main_menu_choice); } 3>&1 || return 0
    [[ $c != 0 ]] || return 0
    ui_clear_screen
    # Explicit back actions set this flag in the current shell.
    UI_SKIP_PAUSE=0
    case $c in
      1) add_node ;;
      2) if select_node ""; then show_node "$SEL_ID"; fi ;;
      3) edit_node ;;
      4) delete_node ;;
      5) sni_test ;;
      6) show_status ;;
      7) show_runtime_config ;;
      8) show_log ;;
      9) service_menu ;;
      10) routing_menu ;;
      11) system_dns_menu ;;
      12) cert_menu ;;
      13) bbr_menu ;;
      14) update_menu ;;
      15) uninstall_all; [[ -x $SB_CMD ]] || return ;;
      *) warn "无效选择" ;;
    esac
    [[ $UI_SKIP_PAUSE == 1 ]] || pause || return 0
    ui_clear_screen
  done
}

update_menu() {
  local c
  ui_title '更新管理'
  ui_item 1 '更新 sing-box 内核'; ui_item 2 '更新 sb 脚本'; ui_item 0 '返回'
  c=$(ask_choice "请选择" 2) || return 0
  ui_clear_screen
  case $c in 1) update_core ;; 2) update_script restart ;; 0) UI_SKIP_PAUSE=1 ;; esac
}
