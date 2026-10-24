#!/usr/bin/env bash
# System resolver configuration, independent of sing-box node configuration.
# Paths can be overridden by isolated tests.
system_dns_show() {
  local file=${SB_RESOLV_CONF:-/etc/resolv.conf}
  ui_title '当前系统 DNS 配置'
  if [[ -L $file ]]; then
    printf '配置链接: %s -> %s\n' "$file" "$(readlink "$file")"
  fi
  if [[ -r $file ]]; then
    cat "$file"
  else
    warn "无法读取 $file"
  fi
  if command -v resolvectl >/dev/null 2>&1; then
    ui_section '系统解析器上游 DNS'
    resolvectl dns 2>/dev/null || true
  fi
}

system_dns_valid_ip() {
  local ip=$1 part count=0 rest left right
  if [[ $ip == *:* ]]; then
    # IPv6 in hexadecimal notation; reject zones, ports and embedded IPv4.
    [[ $ip =~ ^[0-9a-fA-F:]+$ && $ip != *:::* ]] || return 1
    rest=$ip
    if [[ $ip == *::* ]]; then
      left=${ip%%::*}; right=${ip#*::}
      [[ $right != *::* && $left != :* && $left != *: && $right != :* && $right != *: ]] || return 1
      rest=${left}${left:+${right:+:}}${right}
    else
      [[ $ip != :* && $ip != *: ]] || return 1
    fi
    [[ -n $rest ]] || return 0
    local parts=()
    IFS=: read -r -a parts <<< "$rest"
    for part in "${parts[@]}"; do
      [[ $part =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
      count=$((count + 1))
    done
    if [[ $ip == *::* ]]; then ((count < 8)); else ((count == 8)); fi
  else
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    local parts=()
    IFS=. read -r -a parts <<< "$ip"
    for part in "${parts[@]}"; do
      [[ ${#part} -le 3 && ( $part == 0 || $part != 0* ) ]] || return 1
      ((10#$part <= 255)) || return 1
    done
  fi
}

system_dns_set() {
  local file=${SB_RESOLV_CONF:-/etc/resolv.conf}
  local backup=${SB_DNS_BACKUP:-/etc/resolv.conf.sb-backup} ip tmp
  (($# > 0 && $# <= 3)) || { err '请输入 1–3 个 DNS IP 地址'; return 1; }
  for ip in "$@"; do
    system_dns_valid_ip "$ip" || { err "无效的 DNS IP 地址: $ip"; return 1; }
  done
  [[ -e $file || -L $file ]] || { err "配置不存在: $file"; return 1; }
  # Preserve the original object, including a symlink, only on the first change.
  if [[ ! -e $backup && ! -L $backup ]]; then
    cp -Pp "$file" "$backup" || { err 'DNS 备份失败，未修改配置'; return 1; }
  fi
  tmp=$(mktemp "${file}.sb.XXXXXX") || return 1
  if ! {
    printf '# Configured by sb; restore with sb dns\n'
    # Keep local search domains and resolver options.
    if [[ -r $file ]]; then
      awk '$1 == "search" || $1 == "domain" || $1 == "options" {print}' "$file"
    fi
    printf 'nameserver %s\n' "$@"
  } > "$tmp" || ! chmod 644 "$tmp" || ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    err 'DNS 写入失败（文件可能只读或是容器挂载点），原配置未替换'
    return 1
  fi
  info "系统 DNS 已修改为: $*；原配置备份: $backup"
}

system_dns_restore() {
  local file=${SB_RESOLV_CONF:-/etc/resolv.conf}
  local backup=${SB_DNS_BACKUP:-/etc/resolv.conf.sb-backup} tmp
  [[ -e $backup || -L $backup ]] || { err '没有可恢复的 DNS 备份'; return 1; }
  tmp=$(mktemp "${file}.sb.XXXXXX") || return 1
  rm -f "$tmp"
  if ! cp -Pp "$backup" "$tmp" || ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    err 'DNS 恢复失败'
    return 1
  fi
  rm -f "$backup"
  info '已恢复修改前的 DNS 配置'
}

system_dns_menu() {
  local choice input
  local servers=()
  system_dns_show
  ui_section '系统 DNS 管理'
  ui_item 1 '使用 Cloudflare · 1.1.1.1'
  ui_item 2 '使用 Google · 8.8.8.8'
  ui_item 3 '使用 1.1.1.1 + 8.8.8.8'
  ui_item 4 '手动输入 DNS'
  ui_item 5 '恢复修改前的配置'
  ui_item 0 '返回'
  choice=$(ask_choice '请选择' 5) || return 0
  case $choice in
    0) UI_SKIP_PAUSE=1; return 0 ;;
    1) servers=(1.1.1.1) ;;
    2) servers=(8.8.8.8) ;;
    3) servers=(1.1.1.1 8.8.8.8) ;;
    4)
      input=$(ask '输入 1–3 个 IPv4 / IPv6 DNS 地址，以空格分隔（0 返回）') || return 0
      case $input in 0|q|Q) UI_SKIP_PAUSE=1; return 0 ;; esac
      [[ $input =~ [^[:space:]] ]] || { err 'DNS 地址不能为空'; return 1; }
      read -r -a servers <<< "$input"
      ;;
    5)
      confirm '恢复修改前的系统 DNS 配置？' n || return 0
      system_dns_restore; return $? ;;
  esac
  warn '将使用静态 /etc/resolv.conf（如为符号链接则替换链接）；DHCP、NetworkManager 或云初始化可能覆盖它。'
  confirm "将系统 DNS 设置为 ${servers[*]}？" n || return 0
  system_dns_set "${servers[@]}"
}
