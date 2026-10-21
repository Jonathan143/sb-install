#!/usr/bin/env bash
# Source module; loaded by sb.sh.
#---------------------------------------------------------------------
# SNI（Reality）
#---------------------------------------------------------------------
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
  local out rc
  SNI_FAILURE="连接/TLS/证书失败"
  # 不发送 HTTP 请求，避免将目标站的 403/404 当作 TLS 失败。
  # HTTP/2 servers may send binary frames after the handshake. Strip NUL bytes
  # before Bash captures stdout, while preserving timeout/OpenSSL failures.
  if out=$(
    set -o pipefail
    LC_ALL=C timeout "${2:-8}" openssl s_client -connect "$1:443" \
      -servername "$1" -tls1_3 -alpn h2 -verify_hostname "$1" \
      -verify_return_error </dev/null 2>/dev/null | LC_ALL=C tr -d '\000'
  ); then rc=0; else rc=$?; fi
  if ((rc == 124 || rc == 137 || rc == 143)); then SNI_FAILURE="超时"; return 1; fi
  ((rc == 0)) || return 1
  [[ $out == *TLSv1.3* ]] || return 1
  [[ $out == *'Verify return code: 0 (ok)'* ]] || return 1
  [[ $out == *'ALPN protocol: h2'* ]] || { SNI_FAILURE="不支持 h2"; return 1; }
  SNI_FAILURE=""
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
  printf '%s\t%s\t%s\t%s\n' "$ok" "$avg" "$domain" "$reason"
}

sni_scan() ( # 子 shell 隔离临时目录与信号处理；最多 4 个域名并行
  local tmp domain pid i=0 failed=0
  local pids=()
  tmp=$(mktemp -d) || return 1
  trap 'for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || :; done; wait; rm -rf "$tmp"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  while IFS= read -r domain; do
    [[ -n $domain ]] || continue
    sni_measure "$domain" > "$tmp/$i" &
    pids+=("$!"); i=$((i + 1))
    if ((${#pids[@]} == 4)); then
      for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
      pids=()
    fi
  done < <(printf '%s\n' "${SNI_LIST[@]}" "${N_SNI:-}" | awk 'NF && !seen[$0]++')
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
  local ok ms domain state i=0 latency rank
  echo "检测条件：TLS 1.3 + h2 + 证书有效；耗时为本服务器到目标站的连接及握手耗时。"
  printf '  %-4s %-36s %-12s %-7s %s\n' '序号' '域名' '平均耗时' '成功率' '状态'
  while IFS=$'\t' read -r ok ms domain state; do
    rank="-"; latency="-"
    ((ok == 0)) || latency="${ms} ms"
    if ((ok == 3)); then
      i=$((i + 1)); rank=$i
      ((i != 1)) || state="推荐"
    fi
    [[ $domain != "${N_SNI:-}" ]] || state="$state / 当前"
    printf '  %-4s %-36s %-12s %-7s %s\n' "$rank" "$domain" "$latency" "$ok/3" "$state"
  done <<< "$1"
  echo "仅 3/3 通过的域名参与排名，按平均耗时升序排列；此结果不代表客户端实际速度。"
}

sni_test() {
  local results N_SNI=""
  ui_title 'SNI 优选测试'
  if ! command -v timeout >/dev/null || ! sni_now_ms >/dev/null; then
    warn "域名优选需要 timeout 和毫秒计时支持，请安装 coreutils 或使用 Bash 5"
    return 0
  fi
  info "正在优选：每个域名测试 3 次，单次超时 2 秒，最多 4 个域名并行..."
  if ! results=$(sni_scan); then
    warn "优选未完成，请稍后重试"
    return 0
  fi
  sni_show_results "$results"
  if ! awk -F '\t' '$1 == 3 { found=1 } END { exit !found }' <<< "$results"; then
    warn "没有稳定通过的域名，请稍后重试"
  fi
}

pick_sni() { # -> PICKED；取消/输入结束时返回失败，调用者不保存配置
  local mode in cand i results ok ms domain state def
  local ranked=()
  PICKED=""
  echo "Reality SNI: 1) 域名优选（推荐）  2) 手动选择/输入  0) 取消"
  read -rp "请选择 [1]: " mode || return 1
  mode=${mode:-1}
  while true; do
    case $mode in
      0) return 1 ;;
      1)
        if ! command -v timeout >/dev/null || ! sni_now_ms >/dev/null; then
          warn "域名优选需要 timeout 和毫秒计时支持，请安装 coreutils 或使用 Bash 5；可手动选择"
          mode=2; continue
        fi
        info "正在优选：每个域名测试 3 次，单次超时 2 秒，最多 4 个域名并行..."
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
          read -rp "选择排名${def:+ [回车选 1]}，r 重测，m 手动，0 取消: " in || return 1
          in=${in:-$def}
          case $in in
            0) return 1 ;;
            r|R) break ;;
            m|M) mode=2; break ;;
          esac
          if [[ $in =~ ^[0-9]{1,3}$ ]] && ((10#$in >= 1 && 10#$in <= ${#ranked[@]})); then
            PICKED=${ranked[10#$in - 1]}; info "已选择 $PICKED"; return 0
          fi
          warn "请输入有效排名，或选择重测/手动输入"
        done ;;
      2)
        echo "内置 SNI 候选（输入序号或域名；r 返回优选；0 取消）:"
        for i in "${!SNI_LIST[@]}"; do printf '  %2d) %s\n' $((i + 1)) "${SNI_LIST[$i]}"; done
        read -rp "请选择: " in || return 1
        case $in in 0) return 1 ;; r|R) mode=1; continue ;; esac
        if [[ $in =~ ^[0-9]{1,3}$ ]] && ((10#$in >= 1 && 10#$in <= ${#SNI_LIST[@]})); then
          cand=${SNI_LIST[10#$in - 1]}
        else
          cand=$(printf '%s' "$in" | tr '[:upper:]' '[:lower:]')
        fi
        sni_valid_domain "$cand" || { warn "请输入有效域名（不含协议、端口或路径）"; continue; }
        info "检测 $cand 的 TLS 1.3、h2 和证书..."
        if ! check_sni "$cand"; then
          warn "$cand 检测未通过：$SNI_FAILURE，Reality 可能无法正常工作"
          confirm "仍然使用?" n || continue
        fi
        PICKED=$cand; info "已选择 $PICKED"; return 0 ;;
      *) warn "无效选择"; read -rp "1 优选，2 手动，0 取消: " mode || return 1 ;;
    esac
  done
}
