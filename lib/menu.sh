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
  add             新增节点
  list            列出节点
  info [编号]     查看节点链接/二维码/客户端配置
  edit [编号]     修改节点
  del [编号]      删除节点
  status          运行状态、证书到期时间
  config          查看 sing-box 运行配置文件
  log [-f]        查看日志（-f 实时）
  start|stop|restart   服务控制
  dns [show]      系统 DNS 配置 / 查看
  route [show]    出口与分流 / 查看规则
  cert            证书管理
  core            安装/更新 sing-box 内核
  update [--beta] 更新 sb 脚本（--beta 获取最新测试版）
  uninstall       卸载
EOF
}

main_menu() {
  local RED GREEN YELLOW CYAN PLAIN BOLD DIM
  ui_colors 1
  local c st installed line core_label node_count file UI_SKIP_PAUSE=0
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
    ui_item 12 '证书管理'; ui_item 13 '更新内核 / 脚本'
    ui_item 14 '卸载'
    printf '\n'; ui_item 0 '退出（也可输入 q）'
    c=$(ask_choice "请选择" 14) || return 0
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
      13) update_menu ;;
      14) uninstall_all; [[ -x $SB_CMD ]] || return ;;
      0|q) return ;;
      *) warn "无效选择" ;;
    esac
    [[ $UI_SKIP_PAUSE == 1 ]] || pause || return 0
  done
}

update_menu() {
  local c
  ui_title '更新管理'
  ui_item 1 '更新 sing-box 内核'; ui_item 2 '更新 sb 脚本'; ui_item 0 '返回'
  c=$(ask_choice "请选择" 2) || return 0
  case $c in 1) update_core ;; 2) update_script restart ;; 0) UI_SKIP_PAUSE=1 ;; esac
}
