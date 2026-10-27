#!/usr/bin/env bash
# Source module; loaded by sb.sh.
#---------------------------------------------------------------------
# 快照 / 应用 / 回滚
#---------------------------------------------------------------------
snapshot() {
  local tmp old
  LAST_SNAP=""; SNAPSHOT_RESTORED=0
  mkdir -p "$BACKUP_DIR" "$SB_DIR/certs" || return 1
  tmp=$(mktemp "$BACKUP_DIR/snap-$(date +%Y%m%d-%H%M%S).XXXXXX") || return 1
  if ! tar -czf "$tmp" -C "$SB_DIR" conf.d meta certs ||
     ! tar -tzf "$tmp" >/dev/null || ! mv "$tmp" "$tmp.tgz"; then
    rm -f "$tmp"
    err "快照创建失败，已取消变更"
    return 1
  fi
  LAST_SNAP="$tmp.tgz"
  while IFS= read -r old; do rm -f "$old"; done < <(ls -1t "$BACKUP_DIR"/snap-*.tgz | tail -n +11)
  return 0
}
restore_snapshot() {
  local stage dir failed=0 recovery_failed=0
  local dirs=(conf.d meta) installed=()
  [[ -s ${LAST_SNAP:-} ]] || { err "没有可恢复的有效快照"; return 1; }
  stage=$(mktemp -d "$SB_DIR/.restore.XXXXXX") || return 1
  # Extraction failures must never touch the live directories.
  if ! mkdir "$stage/new" "$stage/old" ||
     ! tar -xzf "$LAST_SNAP" -C "$stage/new" ||
     [[ ! -d $stage/new/conf.d || ! -d $stage/new/meta ]]; then
    rm -rf "$stage"
    err "快照损坏或解压失败，现有配置未替换"
    return 1
  fi
  # Older snapshots contain only configuration and metadata.
  [[ ! -d $stage/new/certs ]] || dirs+=(certs)
  for dir in "${dirs[@]}"; do
    if [[ -e $SB_DIR/$dir || -L $SB_DIR/$dir ]]; then
      mv "$SB_DIR/$dir" "$stage/old/$dir" || { failed=1; break; }
    fi
    if mv "$stage/new/$dir" "$SB_DIR/$dir"; then
      installed+=("$dir")
    else
      failed=1; break
    fi
  done
  if ((failed)); then
    for dir in "${installed[@]}"; do
      mv "$SB_DIR/$dir" "$stage/new/$dir" || recovery_failed=1
    done
    for dir in "${dirs[@]}"; do
      if [[ -e $stage/old/$dir || -L $stage/old/$dir ]]; then
        if [[ -e $SB_DIR/$dir || -L $SB_DIR/$dir ]]; then recovery_failed=1
        else mv "$stage/old/$dir" "$SB_DIR/$dir" || recovery_failed=1; fi
      fi
    done
    if ((recovery_failed)); then
      err "恢复目录失败，请保留并检查 $stage 和快照 $LAST_SNAP"
    else
      rm -rf "$stage"
      err "恢复目录失败，已保留恢复操作前的文件"
    fi
    return 1
  fi
  rm -rf "$stage"
  SNAPSHOT_RESTORED=1
  warn "已回滚到变更前的配置"
  return 0
}

# Dynamic scope keeps each node operation's snapshot and certificate state local.
node_change() {
  local LAST_SNAP="" SNAPSHOT_RESTORED=0 NODE_CERT_CHANGED=0 NODE_FILES_CHANGED=0
  local NODE_WAS_ACTIVE=0 NODE_SERVICE_RESTORED=0
  svc is-active && NODE_WAS_ACTIVE=1
  if "$@"; then return 0; fi
  if [[ -n $LAST_SNAP ]] && ((NODE_FILES_CHANGED || NODE_CERT_CHANGED)); then
    if [[ $SNAPSHOT_RESTORED != 1 ]]; then restore_snapshot || return 1; fi
    if ((NODE_SERVICE_RESTORED == 0)); then
      if ((NODE_WAS_ACTIVE)); then
        if ! write_service || ! restart_service_checked; then
          err "配置已恢复，但服务重启失败，请检查日志"
        fi
      elif svc is-active; then
        svc stop >/dev/null 2>&1 || err "无法恢复原来的停止状态，请检查服务状态"
      fi
    fi
  fi
  return 1
}

restart_service_checked() {
  svc restart >/dev/null 2>&1 || { err "服务重启失败"; return 1; }
  sleep 2
  svc is-active || { err "服务重启后未正常运行"; return 1; }
}
# 校验配置并重启，失败自动回滚
apply_config() {
  local log was_active=${NODE_WAS_ACTIVE:-0}
  log=$(mktemp) || return 1
  if [[ -z ${NODE_WAS_ACTIVE+x} ]]; then svc is-active && was_active=1; fi
  sb_args
  if ! route_refresh || ! refresh_builtin_acme_configs || ! "$SB_BIN" "${SB_ARGS[@]}" check >"$log" 2>&1; then
    err "配置校验失败:"; cat "$log" >&2
    rm -f "$log"
    restore_snapshot; return 1
  fi
  rm -f "$log"
  if ! write_service || ! svc enable >/dev/null 2>&1 || ! restart_service_checked || ! write_nodes_txt; then
    err "sing-box 配置应用失败，最近日志:"
    has_systemd && journalctl -u "$SB_SERVICE" -n 15 --no-pager >&2 || tail -n 15 /var/log/sing-box.log >&2 2>/dev/null
    restore_snapshot || return 1
    NODE_SERVICE_RESTORED=1
    if ((was_active)); then
      if ! write_service || ! restart_service_checked; then
        err "配置已恢复，但服务仍未正常运行，请检查日志"
      fi
    else
      svc stop >/dev/null 2>&1 || err "无法恢复原来的停止状态，请检查服务状态"
    fi
    return 1
  fi
  return 0
}
