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

fw_open() { # port tcp|udp|both
  if [[ $2 == both ]]; then fw_open "$1" tcp; fw_open "$1" udp; return $?; fi
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$1/$2" >/dev/null && info "ufw 已放行 $1/$2"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$1/$2" >/dev/null && firewall-cmd --reload >/dev/null && info "firewalld 已放行 $1/$2"
  elif command -v iptables >/dev/null && iptables -S INPUT 2>/dev/null | grep -Eq -- '-P INPUT (DROP|REJECT)|-j (DROP|REJECT)'; then
    iptables -C INPUT -p "$2" --dport "$1" -j ACCEPT 2>/dev/null || iptables -I INPUT -p "$2" --dport "$1" -j ACCEPT
    info "iptables 已放行 $1/$2（如需持久化请自行保存规则）"
  fi
  return 0
}
fw_close() {
  if [[ $2 == both ]]; then fw_close "$1" tcp; fw_close "$1" udp; return $?; fi
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow "$1/$2" >/dev/null 2>&1
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="$1/$2" >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1
  elif command -v iptables >/dev/null; then
    iptables -D INPUT -p "$2" --dport "$1" -j ACCEPT 2>/dev/null
  fi
  return 0
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
