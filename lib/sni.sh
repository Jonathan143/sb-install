#!/usr/bin/env bash
# Source module; loaded by sb.sh.
#---------------------------------------------------------------------
# SNI（Reality）
#---------------------------------------------------------------------
sni_domain_info() { # 域名 -> SNI_CATEGORY；只做本地分类查询
  local entry
  SNI_CATEGORY='自定义域名'
  for entry in "${SNI_CATALOG[@]}"; do
    if [[ ${entry%%|*} == "$1" ]]; then
      SNI_CATEGORY=${entry#*|}
      return 0
    fi
  done
}

sni_ask_mode() {
  local value def=1
  [[ ${SNI_SCAN_MODE:-quick} != all ]] || def=2
  ui_section '检测范围' >&2
  ui_item 1 "快速检测（${#SNI_QUICK_LIST[@]} 个域名，默认）" >&2
  ui_item 2 "检测全部（${#SNI_LIST[@]} 个域名）" >&2
  ui_item 0 '返回' >&2
  value=$(ask_choice '请选择检测范围' 2 "$def") || return 1
  case $value in 1) echo quick ;; 2) echo all ;; *) return 1 ;; esac
}

sni_now_ms() {
  local now
  if [[ -n ${EPOCHREALTIME:-} ]]; then
    now=${EPOCHREALTIME/./}; printf '%s\n' "${now:0:13}"
  else
    now=$(date +%s%3N)
    [[ $now =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$now"
  fi
}

check_sni() { # 域名 [超时秒数]；SNI_FAILURE 返回失败原因
  local output line rc tls=0 verified=0 h2=0
  SNI_FAILURE="连接/TLS/证书失败"
  output=$(mktemp "${SNI_SCAN_TMP:-${TMPDIR:-/tmp}}/handshake.XXXXXX") || { SNI_FAILURE="无法创建检测临时文件"; return 1; }
  # Capture to a file: avoid a command-substitution shell and concurrent tr.
  # GNU timeout supervises OpenSSL with a hard-kill grace period.
  if LC_ALL=C timeout -k 1 "${2:-8}" openssl s_client -connect "$1:443" \
    -servername "$1" -tls1_3 -alpn h2 -verify_hostname "$1" \
    -verify_return_error </dev/null >"$output" 2>/dev/null; then rc=0; else rc=$?; fi
  if ((rc == 0)); then
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line != *TLSv1.3* ]] || tls=1
      [[ $line != *'Verify return code: 0 (ok)'* ]] || verified=1
      [[ $line != *'ALPN protocol: h2'* ]] || h2=1
    done < "$output"
  fi
  rm -f "$output"
  if ((rc == 124 || rc == 137 || rc == 143)); then SNI_FAILURE="超时"; return 1; fi
  ((rc == 0 && tls && verified)) || return 1
  ((h2)) || { SNI_FAILURE="不支持 h2"; return 1; }
  SNI_FAILURE=""
}

sni_progress() { # 域名 [成功次数 平均耗时 状态]；只写 stderr
  local RED GREEN YELLOW CYAN PLAIN BOLD DIM
  local color mark state latency="-" SNI_CATEGORY
  ui_colors 2
  sni_domain_info "$1"
  if (($# == 1)); then
    printf '  %s[%s]  %-36s  [%s] … 检测中%s\n' "$DIM" "${SNI_PROGRESS_LABEL:---/--}" "$1" "$SNI_CATEGORY" "$PLAIN" >&2
    return 0
  fi
  case $2 in
    3) color=$GREEN; mark='✓'; state='通过' ;;
    0) color=$RED; mark='✗'; state=$4 ;;
    *) color=$YELLOW; mark='!'; state=$4 ;;
  esac
  (( $2 == 0 )) || latency="$3 ms"
  printf '  %s[%s]%s  %-36s  [%s] %8s  %s/3  %s%s %s%s\n' \
    "$DIM" "${SNI_PROGRESS_LABEL:---/--}" "$PLAIN" "$1" "$SNI_CATEGORY" "$latency" "$2" "$color" "$mark" "$state" "$PLAIN" >&2
}

sni_measure() { # 域名 -> 成功次数、平均毫秒、域名、状态（TSV）
  local domain=$1 round start end elapsed sum=0 ok=0 avg=0 reason="检测失败"
  for round in 1 2 3; do
    start=$(sni_now_ms) || return 1
    if check_sni "$domain" 2; then
      end=$(sni_now_ms) || return 1
      elapsed=$((end - start)); ((elapsed > 0)) || elapsed=1
      sum=$((sum + elapsed)); ok=$((ok + 1))
    else
      reason=$SNI_FAILURE
    fi
  done
  ((ok == 0)) || avg=$(((sum + ok / 2) / ok))
  if ((ok == 3)); then reason="通过"; elif ((ok > 0)); then reason="不稳定 ($reason)"; fi
  sni_progress "$domain" "$ok" "$avg" "$reason"
  printf '%s\t%s\t%s\t%s\n' "$ok" "$avg" "$domain" "$reason"
}

sni_concurrency() {
  # Keep environment overrides within the supported range.
  case ${SNI_CONCURRENCY:-4} in
    [1-4]) printf '%s\n' "${SNI_CONCURRENCY:-4}" ;;
    *) printf '4\n' ;;
  esac
}

sni_ask_concurrency() {
  local value
  value=$(ask_choice '并发数（1–4，0/q 取消）' 4 "$(sni_concurrency)") || return 1
  [[ $value != 0 ]] || return 1
  printf '%s\n' "$value"
}

sni_pid_budget() { # cgroup v2 PID headroom, including ancestor limits
  local path="" hierarchy controllers entry dir current limit available
  SNI_PID_AVAILABLE=""
  if [[ -r /proc/self/cgroup ]]; then
    while IFS=: read -r hierarchy controllers entry; do
      [[ $hierarchy != 0 ]] || path=$entry
    done < /proc/self/cgroup
  fi
  dir="/sys/fs/cgroup${path%/}"
  while [[ $dir == /sys/fs/cgroup* ]]; do
    if [[ -r $dir/pids.max && -r $dir/pids.current ]]; then
      IFS= read -r limit < "$dir/pids.max"
      IFS= read -r current < "$dir/pids.current"
      if [[ $limit =~ ^[0-9]+$ && $current =~ ^[0-9]+$ ]]; then
        available=$((limit - current))
        if [[ -z $SNI_PID_AVAILABLE ]] || ((available < SNI_PID_AVAILABLE)); then
          SNI_PID_AVAILABLE=$available
        fi
      fi
    fi
    [[ $dir != /sys/fs/cgroup ]] || break
    dir=${dir%/*}
  done
}

sni_limit_concurrency() {
  local capacity
  sni_pid_budget
  SNI_EFFECTIVE_CONCURRENCY=$1
  [[ -n $SNI_PID_AVAILABLE ]] || return 0
  # Reserve room for bookkeeping; each worker also needs timeout/watchdog/OpenSSL.
  capacity=$(((SNI_PID_AVAILABLE - 4) / 5))
  if ((capacity < 1)); then
    warn "容器剩余进程额度不足（剩余 ${SNI_PID_AVAILABLE}），已停止测试；请先结束旧测试或提高容器 PID 上限"
    return 1
  fi
  if ((capacity < SNI_EFFECTIVE_CONCURRENCY)); then
    SNI_EFFECTIVE_CONCURRENCY=$capacity
    warn "容器剩余进程额度为 ${SNI_PID_AVAILABLE}，并发数已从 $1 降为 $capacity"
  fi
}

sni_scan() ( # 子 shell 隔离临时目录与信号处理；并发数 1–4
  local tmp domain seen pid i=0 failed=0 concurrency label SNI_SCAN_TMP SNI_PROGRESS_LABEL
  local pids=() domains=() candidates=()
  case ${SNI_SCAN_MODE:-quick} in
    quick) candidates=("${SNI_QUICK_LIST[@]}"); label='快速检测' ;;
    all) candidates=("${SNI_LIST[@]}"); label='检测全部' ;;
    *) warn '无效的 SNI 检测范围'; return 1 ;;
  esac
  concurrency=$(sni_concurrency)
  sni_limit_concurrency "$concurrency" || return 1
  concurrency=$SNI_EFFECTIVE_CONCURRENCY
  tmp=$(mktemp -d) || return 1
  SNI_SCAN_TMP=$tmp
  trap 'for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || :; done; wait; rm -rf "$tmp"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Deduplicate with Bash builtins, without a process substitution/awk pipeline.
  for domain in "${candidates[@]}" "${N_SNI:-}"; do
    [[ -n $domain ]] || continue
    for seen in "${domains[@]}"; do
      [[ $seen != "$domain" ]] || continue 2
    done
    domains+=("$domain")
  done
  ui_section '测试进度' >&2
  printf '  %s · 候选 %s 个 · 并发 %s · 每域名 3 次\n' "$label" "${#domains[@]}" "$concurrency" >&2
  [[ -z ${N_SNI:-} ]] || printf '  包含当前 SNI：%s（自动去重）\n' "$N_SNI" >&2
  printf '  单次超时 2s + 强制结束宽限 1s · TLS 1.3 / h2 / 有效证书\n\n' >&2
  for domain in "${domains[@]}"; do
    printf -v SNI_PROGRESS_LABEL '%02d/%02d' "$((i + 1))" "${#domains[@]}"
    sni_progress "$domain"
    if ((concurrency == 1)); then
      sni_measure "$domain" > "$tmp/$i" || return 1
    else
      sni_measure "$domain" > "$tmp/$i" &
      pids+=("$!")
      if ((${#pids[@]} == concurrency)); then
        for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
        pids=()
        ((failed == 0)) || return 1
      fi
    fi
    i=$((i + 1))
  done
  for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
  pids=()
  ((failed == 0 && i > 0)) || return 1
  LC_ALL=C sort -t $'\t' -k1,1nr -k2,2n -k3,3 "$tmp"/*
)

sni_valid_domain() {
  local label
  local labels=()
  ((${#1} <= 253)) && [[ $1 == *.* && $1 != *[!a-zA-Z0-9.-]* && $1 != *..* ]] || return 1
  [[ $1 != .* && $1 != *. && ! $1 =~ ^[0-9.]+$ ]] || return 1
  IFS=. read -r -a labels <<< "$1"
  for label in "${labels[@]}"; do
    ((${#label} <= 63)) && [[ $label != -* && $label != *- ]] || return 1
  done
}

sni_show_results() { # 已排序的 TSV 结果；仅展示，不修改节点
  local RED GREEN YELLOW CYAN PLAIN BOLD DIM
  local ok ms domain state i=0 latency rank color total=0 partial=0 failed=0
  local best="" best_ms="" SNI_CATEGORY
  ui_colors 1
  ui_section '优选结果'
  printf '  排名  %-38s  %14s  %10s  状态 / 分类\n' '域名' '平均耗时' '成功率'
  printf '  %s────────────────────────────────────────────────────────────────────────────%s\n' "$DIM" "$PLAIN"
  while IFS=$'\t' read -r ok ms domain state; do
    total=$((total + 1))
    rank="-"; latency="-"; color=$RED
    ((ok == 0)) || latency="${ms} ms"
    if ((ok == 3)); then
      i=$((i + 1)); rank=$i; color=$GREEN
      if ((i == 1)); then state="本轮最快"; best=$domain; best_ms=$ms; fi
    elif ((ok > 0)); then
      partial=$((partial + 1)); color=$YELLOW
    else
      failed=$((failed + 1))
    fi
    [[ $domain != "${N_SNI:-}" ]] || state="$state / 当前"
    sni_domain_info "$domain"
    printf '  %s%-4s%s  %-36s  %10s  %7s  %s%s%s / [%s]\n' \
      "$color" "$rank" "$PLAIN" "$domain" "$latency" "$ok/3" "$color" "$state" "$PLAIN" "$SNI_CATEGORY"
  done <<< "$1"
  printf '\n  共 %s 个 · 通过 %s · 不稳定 %s · 未通过 %s\n' "$total" "$i" "$partial" "$failed"
  if [[ -n $best ]]; then
    printf '  %s本轮握手最快%s  %s · %s ms\n' "$GREEN$BOLD" "$PLAIN" "$best" "$best_ms"
  fi
  printf '  %s仅 3/3 通过的域名参与排名，按平均握手耗时升序排列。\n' "$DIM"
  printf '  耗时为本服务器到目标站的连接及握手耗时，不代表客户端实际速度。%s\n' "$PLAIN"
}

sni_test() {
  local results in setup=1 N_SNI="" SNI_SCAN_MODE=quick SNI_CONCURRENCY=${SNI_CONCURRENCY:-4}
  ui_title 'SNI 优选测试'
  if ! has_gnu_timeout || ! sni_now_ms >/dev/null; then
    warn "域名优选需要 GNU timeout（coreutils）和毫秒计时支持（Bash 5 或 GNU date）"
    return 0
  fi
  while true; do
    if ((setup)); then
      SNI_SCAN_MODE=$(sni_ask_mode) || { UI_SKIP_PAUSE=1; return 0; }
      SNI_CONCURRENCY=$(sni_ask_concurrency) || { UI_SKIP_PAUSE=1; return 0; }
      setup=0
    fi
    if ! results=$(sni_scan); then
      warn "优选未完成，请稍后重试"
      return 0
    fi
    sni_show_results "$results"
    if ! awk -F '\t' '$1 == 3 { found=1 } END { exit !found }' <<< "$results"; then
      warn "没有稳定通过的域名，请稍后重试"
    fi
    while true; do
      in=$(ask 'r 重测，s 切换范围，0 返回' 0) || { UI_SKIP_PAUSE=1; return 0; }
      case $in in
        0|q|Q) UI_SKIP_PAUSE=1; return 0 ;;
        r|R) break ;;
        s|S) setup=1; break ;;
        *) warn '请输入 r、s 或 0' ;;
      esac
    done
  done
}

pick_sni() { # -> PICKED；取消/输入结束时返回失败，调用者不保存配置
  local mode in cand i results ok ms domain state def setup=1 SNI_CATEGORY
  local SNI_SCAN_MODE=quick
  local SNI_CONCURRENCY=${SNI_CONCURRENCY:-4}
  local ranked=()
  PICKED=""
  echo "Reality SNI: 1) 域名优选（推荐）  2) 手动选择/输入  0) 取消"
  read -erp "请选择 [1]: " mode || return 1
  mode=${mode:-1}
  while true; do
    case $mode in
      0) return 1 ;;
      1)
        if ! has_gnu_timeout || ! sni_now_ms >/dev/null; then
          warn "域名优选需要 GNU timeout（coreutils）和毫秒计时支持（Bash 5 或 GNU date）；可手动选择"
          mode=2; continue
        fi
        if ((setup)); then
          SNI_SCAN_MODE=$(sni_ask_mode) || return 1
          SNI_CONCURRENCY=$(sni_ask_concurrency) || return 1
          setup=0
        fi
        if ! results=$(sni_scan); then
          warn "优选未完成，可手动选择"; mode=2; continue
        fi
        ranked=()
        sni_show_results "$results"
        while IFS=$'\t' read -r ok ms domain state; do
          if ((ok == 3)); then ranked+=("$domain"); fi
        done <<< "$results"
        def=""; ((${#ranked[@]} == 0)) || def=1
        [[ -n $def ]] || warn "没有稳定通过的域名；可重测或手动输入，不会自动使用失败域名"
        while true; do
          read -erp "选择排名${def:+ [回车选 1]}，r 重测，s 切换范围，m 手动，0 取消: " in || return 1
          in=${in:-$def}
          case $in in
            0|q|Q) return 1 ;;
            r|R) break ;;
            s|S) setup=1; break ;;
            m|M) mode=2; break ;;
          esac
          if [[ $in =~ ^[0-9]{1,3}$ ]] && ((10#$in >= 1 && 10#$in <= ${#ranked[@]})); then
            PICKED=${ranked[10#$in - 1]}; info "已选择 $PICKED"; return 0
          fi
          warn "请输入有效排名，或选择重测/切换范围/手动输入"
        done ;;
      2)
        echo "内置 SNI 候选（输入序号或域名；r 返回优选；0 取消）:"
        for i in "${!SNI_LIST[@]}"; do
          sni_domain_info "${SNI_LIST[$i]}"
          printf '  %2d) %-36s [%s]\n' $((i + 1)) "${SNI_LIST[$i]}" "$SNI_CATEGORY"
        done
        read -erp "请选择: " in || return 1
        case $in in 0|q|Q) return 1 ;; r|R) mode=1; setup=1; continue ;; esac
        if [[ $in =~ ^[0-9]{1,3}$ ]] && ((10#$in >= 1 && 10#$in <= ${#SNI_LIST[@]})); then
          cand=${SNI_LIST[10#$in - 1]}
        else
          cand=$(printf '%s' "$in" | tr '[:upper:]' '[:lower:]')
        fi
        sni_valid_domain "$cand" || { warn "请输入有效域名（不含协议、端口或路径）"; continue; }
        sni_domain_info "$cand"
        info "检测 $cand [$SNI_CATEGORY] 的 TLS 1.3、h2 和证书..."
        if ! check_sni "$cand"; then
          warn "$cand 检测未通过：$SNI_FAILURE，Reality 可能无法正常工作"
          confirm "仍然使用?" n || continue
        fi
        PICKED=$cand; info "已选择 $PICKED"; return 0 ;;
      *) warn "无效选择"; read -erp "1 优选，2 手动，0 取消: " mode || return 1 ;;
    esac
  done
}
