#!/usr/bin/env bash
# Source module; loaded by sb.sh.
#---------------------------------------------------------------------
# 快照 / 应用 / 回滚
#---------------------------------------------------------------------
snapshot() {
  LAST_SNAP="$BACKUP_DIR/snap-$(date +%Y%m%d-%H%M%S).tgz"
  tar -czf "$LAST_SNAP" -C "$SB_DIR" conf.d meta 2>/dev/null
  ls -1t "$BACKUP_DIR"/snap-*.tgz 2>/dev/null | tail -n +11 | xargs -r rm -f
}
restore_snapshot() {
  [[ -f $LAST_SNAP ]] || return 1
  rm -rf "$CONF_DIR" "$META_DIR"
  tar -xzf "$LAST_SNAP" -C "$SB_DIR"
  warn "已回滚到变更前的配置"
}
# 校验配置并重启，失败自动回滚
apply_config() {
  local log=/tmp/sb-check.log
  sb_args
  if ! "$SB_BIN" "${SB_ARGS[@]}" check >"$log" 2>&1; then
    err "配置校验失败:"; cat "$log" >&2
    restore_snapshot; return 1
  fi
  write_service
  svc enable >/dev/null 2>&1
  svc restart >/dev/null 2>&1
  sleep 2
  if ! svc is-active; then
    err "sing-box 启动失败，最近日志:"
    has_systemd && journalctl -u "$SB_SERVICE" -n 15 --no-pager >&2 || tail -n 15 /var/log/sing-box.log >&2 2>/dev/null
    restore_snapshot; write_service; svc restart >/dev/null 2>&1
    return 1
  fi
  write_nodes_txt
  return 0
}
