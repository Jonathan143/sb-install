#!/usr/bin/env bash
# Source module; loaded by sb.sh.
# fdinfo identifies the open file description holding the lock, including locks
# inherited by children. Merely opening the same file does not make a holder.
lock_pid_holds() {
  local pid=$1
  [[ $pid =~ ^[0-9]+$ && $pid != $$ && $pid != "$BASHPID" ]] || return 1
  [[ /proc/$pid/fd/9 -ef $SB_LOCK ]] || return 1
  grep -Eq '^lock:.* FLOCK +ADVISORY +WRITE ' "/proc/$pid/fdinfo/9" 2>/dev/null
}
lock_holders() {
  local entry pid
  for entry in /proc/[0-9]*/fd/9; do
    pid=${entry#/proc/}; pid=${pid%%/*}
    lock_pid_holds "$pid" && printf '%s\n' "$pid"
  done
  return 0
}
lock_start_time() {
  local stat
  IFS= read -r stat < "/proc/$1/stat" || return 1
  # comm may contain spaces and parentheses; starttime is field 22.
  stat=${stat##*) }
  awk '{print $20}' <<< "$stat"
}
lock_is_manager() {
  local pid=$1 exe arg first=yes script=""
  exe=$(readlink "/proc/$pid/exe") || return 1
  [[ ${exe##*/} == bash ]] || return 1
  while IFS= read -r -d '' arg; do
    if [[ $first == yes ]]; then first=no; continue; fi
    case $arg in
      -c|-*c*) return 1 ;;
      -*) continue ;;
      *) script=$arg; break ;;
    esac
  done < "/proc/$pid/cmdline"
  [[ -n $script ]] || return 1
  [[ $script == /* ]] || script="/proc/$pid/cwd/$script"
  [[ $script == "$SB_CMD" || $script -ef $SB_CMD || $script -ef $SB_ENTRY ]]
}
lock_show_process() {
  local pid=$1 arg
  printf 'PID: %s\n' "$pid" >&2
  # BusyBox ps may not support these columns; /proc still supplies the command.
  ps -p "$pid" -o pid,ppid,user,etime,args >&2 2>/dev/null && return 0
  printf '命令: ' >&2
  while IFS= read -r -d '' arg; do printf '%q ' "$arg" >&2; done < "/proc/$pid/cmdline"
  printf '\n' >&2
}
lock_interactive() { [[ -t 0 ]]; }
acquire_lock() {
  command -v flock >/dev/null || return 0
  exec 9>>"$SB_LOCK" || { err "无法打开锁文件: $SB_LOCK"; return 1; }
  flock -n 9 && return 0
  local pid start current i
  local managers=() starts=()
  warn "已有另一个 sb 实例正在运行，占用进程信息:"
  while IFS= read -r pid; do
    lock_show_process "$pid"
    start=$(lock_start_time "$pid" 2>/dev/null) || continue
    if [[ -n $start ]] && lock_is_manager "$pid" 2>/dev/null; then
      managers+=("$pid"); starts+=("$start")
    fi
  done < <(lock_holders)
  # The previous process may have exited while we were inspecting it.
  flock -n 9 && return 0
  if ((${#managers[@]} == 0)); then
    err "无法确认持锁的 sb 管理进程，请根据进程信息手动处理后重试"
    return 1
  fi
  lock_interactive || { err "非交互运行不会终止其他实例，请在终端运行 sb 处理"; return 1; }
  warn "终止管理进程及其持锁子 shell 可能中断正在执行的操作"
  confirm "是否终止以下 sb 进程并继续: ${managers[*]}?" n || return 1
  flock -n 9 && return 0
  # Validate the entire approved set before sending any signal. Bash subshells
  # inherit both the lock descriptor and the manager's command line.
  for ((i=0; i<${#managers[@]}; i++)); do
    pid=${managers[i]}; start=${starts[i]}
    current=$(lock_start_time "$pid" 2>/dev/null) || current=""
    if [[ $current != "$start" ]] || ! lock_pid_holds "$pid" || ! lock_is_manager "$pid"; then
      err "占用进程已变化，未发送终止信号，请重试"
      return 1
    fi
  done
  for ((i=0; i<${#managers[@]}; i++)); do
    pid=${managers[i]}; start=${starts[i]}
    # A previous TERM may have caused another approved process to exit. Never
    # signal a reused PID or a process that no longer holds this lock.
    current=$(lock_start_time "$pid" 2>/dev/null) || current=""
    if [[ $current != "$start" ]] || ! lock_pid_holds "$pid" || ! lock_is_manager "$pid"; then
      continue
    fi
    if ! kill -TERM "$pid"; then
      flock -n 9 && return 0
      err "无法终止进程 $pid，请检查权限后重试"
      return 1
    fi
  done
  if flock -w 5 9; then
    info "已取得运行锁，继续启动"
    return 0
  fi
  err "终止请求已发送，但锁尚未释放（进程可能正在执行命令，或子进程继承了锁）"
  while IFS= read -r pid; do lock_show_process "$pid"; done < <(lock_holders)
  err "请等待操作结束或手动处理上述进程后重试；不要删除锁文件"
  return 1
}
