#!/usr/bin/env bash
# Source module; loaded by sb.sh.
#---------------------------------------------------------------------
# 端口 / 防火墙
#---------------------------------------------------------------------
port_in_use() { # port tcp|udp|both; either socket counts as occupied
  if [[ $2 == both ]]; then port_in_use "$1" tcp || port_in_use "$1" udp; return $?; fi
  local flag=-ltn; [[ $2 == udp ]] && flag=-lun
  ss -H $flag 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"
}
port_listening() { # both requires TCP and UDP listeners
  if [[ $2 == both ]]; then port_in_use "$1" tcp && port_in_use "$1" udp; return $?; fi
  port_in_use "$1" "$2"
}
node_port_used() { # port [跳过的节点ID]
  local id
  for id in $(list_ids); do
    [[ $id == "${2:-}" ]] && continue
    grep -q "^N_LPORT=$1\$" "$META_DIR/$id.env" && return 0
  done
  return 1
}
rand_port() { # tcp|udp|both 跳过ID
  local i p
  for i in $(seq 1 300); do
    p=$((PORT_MIN + (RANDOM * 32768 + RANDOM) % (PORT_MAX - PORT_MIN + 1)))
    port_in_use "$p" "$1" || node_port_used "$p" "${2:-}" || { echo "$p"; return 0; }
  done
  return 1
}
# pick_port tcp|udp|both [跳过ID] [当前端口] -> PICKED
pick_port() {
  local net=$1 skip=${2:-} cur=${3:-} in p
  while true; do
    in=$(ask "监听端口（回车随机 ${PORT_MIN}-${PORT_MAX}；输入 起-止 可修改随机范围）") || return 1
    if [[ -z $in ]]; then
      p=$(rand_port "$net" "$skip") || { warn "范围内没有空闲端口，请修改范围"; continue; }
      info "已随机选择端口 $p"
    elif [[ $in =~ ^([0-9]+)-([0-9]+)$ ]]; then
      if ((BASH_REMATCH[1] >= 1 && BASH_REMATCH[1] < BASH_REMATCH[2] && BASH_REMATCH[2] <= 65535)); then
        PORT_MIN=${BASH_REMATCH[1]}; PORT_MAX=${BASH_REMATCH[2]}; save_conf
        info "随机范围已改为 ${PORT_MIN}-${PORT_MAX}，请重新输入或回车随机"
      else
        warn "范围无效"
      fi
      continue
    elif [[ $in =~ ^[0-9]+$ ]] && ((in >= 1 && in <= 65535)); then
      p=$in
    else
      warn "输入无效"; continue
    fi
    if [[ $p != "$cur" ]] && { port_in_use "$p" "$net" || node_port_used "$p" "$skip"; }; then
      warn "端口 $p 已被占用"; continue
    fi
    PICKED=$p; return 0
  done
}
ask_pub_port() { # 默认值
  local p
  while true; do
    p=$(ask "对外端口（NAT 机器填商家映射的外部端口，否则直接回车）" "$1") || return 1
    [[ $p =~ ^[0-9]+$ ]] && ((p >= 1 && p <= 65535)) && { echo "$p"; return; }
    warn "端口无效"
  done
}

# Ledger entries: backend|scope|zone|port|protocol. Only rules created by sb
# are owned; keep this ledger outside configuration snapshots.
fw_record() {
  local entry=$1 tmp
  mkdir -p "$SB_DIR" || return 1
  tmp=$(mktemp "$SB_DIR/.firewall.XXXXXX") || return 1
  if ! { if [[ -f $SB_DIR/firewall.rules ]]; then cat "$SB_DIR/firewall.rules" || { rm -f "$tmp"; return 1; }; fi; printf '%s\n' "$entry"; } > "$tmp" ||
     ! chmod 600 "$tmp" || ! mv -f "$tmp" "$SB_DIR/firewall.rules"; then
    rm -f "$tmp"; return 1
  fi
}
fw_forget() {
  local tmp
  tmp=$(mktemp "$SB_DIR/.firewall.XXXXXX") || return 1
  if ! awk -v entry="$1" '$0 != entry' "$SB_DIR/firewall.rules" > "$tmp" ||
     ! chmod 600 "$tmp" || ! mv -f "$tmp" "$SB_DIR/firewall.rules"; then
    rm -f "$tmp"; return 1
  fi
}
fw_has_rule() { # 0 present, 1 absent, 2 inspection failed
  local backend=$1 scope=$2 zone=$3 port=$4 proto=$5 output rc
  local args=()
  case $backend in
    ufw)
      output=$(LC_ALL=C ufw status) || return 2
      [[ $output == *'Status: active'* ]] || return 2
      awk -v rule="$port/$proto" '
        $1 == rule {
          i=2; if ($i == "(v6)") i++
          if ($i != "ALLOW") next
          i++; if ($i == "IN") i++
          if ($i == "Anywhere") found=1
        }
        END {exit !found}' <<< "$output" ;;
    firewalld)
      [[ $scope != permanent ]] || args+=(--permanent)
      firewall-cmd ${args[@]+"${args[@]}"} --zone="$zone" --query-port="$port/$proto" >/dev/null 2>&1 && return 0
      rc=$?; ((rc == 1)) && return 1; return 2 ;;
    iptables)
      iptables -S INPUT >/dev/null 2>&1 || return 2
      iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 && return 0
      rc=$?; ((rc == 1)) && return 1; return 2 ;;
    *) return 2 ;;
  esac
}
fw_change_rule() {
  local action=$1 backend=$2 scope=$3 zone=$4 port=$5 proto=$6
  local args=()
  case $backend in
    ufw)
      [[ $action != remove ]] || args+=(delete)
      ufw ${args[@]+"${args[@]}"} allow "$port/$proto" >/dev/null ;;
    firewalld)
      [[ $scope != permanent ]] || args+=(--permanent)
      firewall-cmd ${args[@]+"${args[@]}"} --zone="$zone" "--$action-port=$port/$proto" >/dev/null ;;
    iptables)
      [[ $action == add ]] && action=-I || action=-D
      iptables "$action" INPUT -p "$proto" --dport "$port" -j ACCEPT ;;
  esac
}
fw_ensure_rule() {
  local backend=$1 scope=$2 zone=$3 port=$4 proto=$5 rc entry="$1|$2|$3|$4|$5"
  fw_has_rule "$@" && return 0
  rc=$?
  ((rc == 1)) || { err "无法查询防火墙规则: $entry"; return 1; }
  if ! grep -Fxq "$entry" "$SB_DIR/firewall.rules" 2>/dev/null; then
    fw_record "$entry" || return 1
  fi
  # Record before mutation, including partial failures, so rollback can clean up.
  NODE_FW_ADDED+=("$entry")
  if ! fw_change_rule add "$@" || ! fw_has_rule "$@"; then
    err "防火墙放行失败: $port/$proto ($backend/$scope)"; return 1
  fi
}
fw_remove_entry() {
  local backend scope zone port proto rc
  IFS='|' read -r backend scope zone port proto <<< "$1"
  if fw_has_rule "$backend" "$scope" "$zone" "$port" "$proto"; then
    fw_change_rule remove "$backend" "$scope" "$zone" "$port" "$proto" || return 1
    fw_has_rule "$backend" "$scope" "$zone" "$port" "$proto" && return 1
    rc=$?
  else rc=$?; fi
  ((rc == 1)) || { err "无法确认规则已清理，保留记录: $1"; return 1; }
  fw_forget "$1"
}
fw_open() { # port tcp|udp|both
  local status zone
  if [[ $2 == both ]]; then fw_open "$1" tcp && fw_open "$1" udp; return $?; fi
  if command -v ufw >/dev/null; then
    status=$(LC_ALL=C ufw status) || { err '无法读取 ufw 状态'; return 1; }
    if [[ $status == *'Status: active'* ]]; then fw_ensure_rule ufw runtime - "$@"; return $?; fi
  fi
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    zone=$(firewall-cmd --get-default-zone) || return 1
    fw_ensure_rule firewalld permanent "$zone" "$@" && fw_ensure_rule firewalld runtime "$zone" "$@"
    return $?
  fi
  if command -v iptables >/dev/null; then
    status=$(iptables -S INPUT) || { err '无法读取 iptables 状态'; return 1; }
    if grep -Eq -- '-P INPUT (DROP|REJECT)|-j (DROP|REJECT)' <<< "$status"; then
      fw_ensure_rule iptables runtime - "$@" || return 1
    fi
  fi
  return 0
}
fw_port_referenced() (
  local id net
  for id in $(list_ids); do
    meta_load "$id" || return 2
    net=$(proto_net)
    [[ $N_LPORT != "$1" || ( $net != "$2" && $net != both ) ]] || return 0
  done
  if [[ ${SB_MODE:-takeover} == coexist && -f $SB_DIR/config.json ]]; then
    # A legacy inbound on the same port keeps the administrator's access intact.
    jq -e --argjson port "$1" 'any(.inbounds[]?; .listen_port == $port)' "$SB_DIR/config.json" >/dev/null
    case $? in 0) return 0 ;; 1) ;; *) return 2 ;; esac
  fi
  return 1
)
fw_close() {
  local entry backend scope zone port proto rc failed=0
  if [[ $2 == both ]]; then
    fw_close "$1" tcp || failed=1
    fw_close "$1" udp || failed=1
    return "$failed"
  fi
  if [[ ${FW_UNINSTALL:-0} != 1 ]]; then
    fw_port_referenced "$@" && return 0
    rc=$?; ((rc == 1)) || return 1
  fi
  [[ -f $SB_DIR/firewall.rules ]] || return 0
  while IFS= read -r entry; do
    IFS='|' read -r backend scope zone port proto <<< "$entry"
    [[ $port == "$1" && $proto == "$2" ]] || continue
    fw_remove_entry "$entry" || failed=1
  done < "$SB_DIR/firewall.rules"
  return "$failed"
}

detect_ip() {
  local ip u
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ip.sb; do
    ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
  done
  ip=$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]')
  [[ $ip == *:* ]] && echo "$ip"
  return 0
}
host_fmt() { [[ $N_HOST == *:* ]] && echo "[$N_HOST]" || echo "$N_HOST"; }
