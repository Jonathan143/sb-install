#!/usr/bin/env bash
# Client-side port hopping for provider-managed UDP forwarding.
hy2_hop_range_valid() {
  local range=$1
  [[ $range =~ ^([1-9][0-9]{0,4})-([1-9][0-9]{0,4})$ ]] || return 1
  ((BASH_REMATCH[1] < BASH_REMATCH[2] && BASH_REMATCH[2] <= 65535))
}
hy2_hop_interval_valid() {
  [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (($1 >= 5 && $1 <= 86400))
}
validate_hy2_hop() {
  [[ -n ${N_HOP_PORTS:-} ]] || return 0
  [[ $N_PROTO == hy2 ]] && hy2_hop_range_valid "$N_HOP_PORTS" &&
    hy2_hop_interval_valid "${N_HOP_INTERVAL:-30}" && return 0
  err 'Hysteria2 跳跃配置无效：范围为 起-止（1–65535），间隔为 5–86400 秒'
  return 1
}
pick_hy2_hop() {
  local range interval
  [[ $N_PROTO == hy2 ]] || { err '仅 Hysteria2 支持端口跳跃'; return 1; }
  info '商家须将整个对外 UDP 范围转发到本节点监听端口；此设置不修改本机防火墙。'
  while true; do
    range=$(ask '跳跃对外端口范围（如 20000-30000；0 关闭；q 取消）' "${N_HOP_PORTS:-0}") || return 1
    case $range in
      q|Q) return 1 ;;
      0) N_HOP_PORTS=''; N_HOP_INTERVAL=''; return 0 ;;
    esac
    hy2_hop_range_valid "$range" && break
    warn '请输入有效的 起-止 范围（1–65535，起始端口小于结束端口）'
  done
  while true; do
    interval=$(ask '跳跃间隔（秒，5–86400；q 取消）' "${N_HOP_INTERVAL:-30}") || return 1
    case $interval in q|Q) return 1 ;; esac
    hy2_hop_interval_valid "$interval" && break
    warn '请输入 5–86400 的整数秒数'
  done
  N_HOP_PORTS=$range; N_HOP_INTERVAL=$interval
}

node_mihomo_hy2() {
  [[ $N_PROTO == hy2 ]] || return 1
  validate_hy2_hop || return 1
  jq -nr --arg name "${N_NOTE:-hy2-$N_ID}" --arg server "$N_HOST" --argjson port "$N_PPORT" \
    --arg pw "$N_PASS" --arg sni "$N_DOMAIN" --arg obfs "$N_OBFS" \
    --argjson insecure "${N_INSECURE:-0}" --arg ports "${N_HOP_PORTS:-}" --arg interval "${N_HOP_INTERVAL:-30}" '
    "proxies:\n  - name: \($name|tojson)\n    type: hysteria2\n    server: \($server|tojson)\n    port: \($port)\n    password: \($pw|tojson)\n    sni: \($sni|tojson)\n    skip-cert-verify: \($insecure == 1)\n    alpn: [h3]" +
    (if $obfs != "" then "\n    obfs: salamander\n    obfs-password: \($obfs|tojson)" else "" end) +
    (if $ports != "" then "\n    ports: \($ports|tojson)\n    hop-interval: \($interval)" else "" end)'
}
