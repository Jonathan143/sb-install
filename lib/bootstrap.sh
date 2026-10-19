#!/usr/bin/env bash
# Source module; loaded by sb.sh.
#---------------------------------------------------------------------
# 初始化 / 自安装
#---------------------------------------------------------------------
self_install() {
  [[ $0 == "$SB_CMD" ]] && return 0
  mkdir -p "$(dirname "$SB_CMD")"
  if [[ -n ${SB_SOURCE_DIR:-} ]]; then
    bash "$SB_SOURCE_DIR/scripts/build.sh" "$SB_CMD.new" && mv -f "$SB_CMD.new" "$SB_CMD" || return 1
  elif [[ -f $0 && -r $0 ]]; then
    install -m 755 "$0" "$SB_CMD.new" && mv -f "$SB_CMD.new" "$SB_CMD"
  elif [[ -n $SCRIPT_URL ]]; then
    curl -fsSL "$SCRIPT_URL" -o "$SB_CMD.new" && chmod +x "$SB_CMD.new" && mv -f "$SB_CMD.new" "$SB_CMD"
  else
    warn "无法自动安装 sb 命令（管道运行且未设置 SCRIPT_URL），请手动: cp 脚本 $SB_CMD && chmod +x $SB_CMD"
    return 1
  fi
  info "已安装快捷命令，之后直接输入 sb 即可"
}

ensure_init() {
  local c ts
  mkdir -p "$CONF_DIR" "$META_DIR" "$CERT_DIR" "$BACKUP_DIR" "$SB_WORKDIR"
  chmod 700 "$SB_DIR"
  if [[ ! -f $SB_CONF ]]; then
    if [[ -f $SB_DIR/config.json ]]; then
      echo
      warn "检测到已有配置 $SB_DIR/config.json（非本脚本生成）"
      echo "  1) 备份后由脚本接管（旧配置备份为 config.json.bak.时间，不再加载）"
      echo "  2) 保留旧配置，脚本只管理新增节点（两者合并加载）"
      c=$(ask_choice "请选择" 2 1) || return 1
      [[ $c != 0 ]] || return 1
      if [[ $c == 2 ]]; then
        SB_MODE=coexist
      else
        ts=$(date +%Y%m%d-%H%M%S)
        mv "$SB_DIR/config.json" "$SB_DIR/config.json.bak.$ts"
        info "旧配置已备份到 config.json.bak.$ts"
        SB_MODE=takeover
      fi
    else
      SB_MODE=takeover
    fi
    save_conf
  fi
  [[ $SB_MODE == takeover && ! -f $CONF_DIR/00-base.json ]] && write_base
  return 0
}

bootstrap() {
  mkdir -p "$SB_DIR"
  load_conf
  install_deps
  self_install || return 1
  ensure_init || return 1
  save_conf
}
