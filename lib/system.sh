#!/usr/bin/env bash
# Source module; loaded by sb.sh.
#---------------------------------------------------------------------
# 系统 / 依赖
#---------------------------------------------------------------------
detect_pkg() {
  if command -v apt-get >/dev/null; then PKG=apt
  elif command -v dnf >/dev/null; then PKG=dnf
  elif command -v yum >/dev/null; then PKG=yum
  elif command -v apk >/dev/null; then PKG=apk
  else PKG=""; fi
}
pkg_install() {
  case $PKG in
    apt) apt-get update -y >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf|yum) "$PKG" install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
    *) err "未识别的包管理器，请手动安装: $*"; return 1 ;;
  esac
}
install_deps() {
  local need=() c
  detect_pkg
  for c in curl jq openssl tar; do command -v "$c" >/dev/null || need+=("$c"); done
  command -v timeout >/dev/null || need+=(coreutils)
  command -v ss >/dev/null || need+=("$([[ $PKG == dnf || $PKG == yum ]] && echo iproute || echo iproute2)")
  if ((${#need[@]})); then
    info "安装依赖: ${need[*]}"
    pkg_install ca-certificates "${need[@]}" >/dev/null 2>&1 || pkg_install "${need[@]}" || die "依赖安装失败"
  fi
  command -v qrencode >/dev/null || pkg_install qrencode >/dev/null 2>&1 || true
}

get_arch() {
  case $(uname -m) in
    x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;;
    armv7*) echo armv7 ;; i386|i686) echo 386 ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

has_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; }
svc() {
  local a=$1
  if has_systemd; then
    case $a in
      is-active) systemctl is-active --quiet "$SB_SERVICE" ;;
      *) systemctl "$a" "$SB_SERVICE" ;;
    esac
  else
    case $a in
      enable) rc-update add "$SB_SERVICE" default >/dev/null 2>&1 ;;
      disable) rc-update del "$SB_SERVICE" default >/dev/null 2>&1 ;;
      is-active) rc-service "$SB_SERVICE" status >/dev/null 2>&1 ;;
      *) rc-service "$SB_SERVICE" "$a" ;;
    esac
  fi
}
