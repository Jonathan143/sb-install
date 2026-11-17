#!/bin/sh
# POSIX entry for minimal Linux images; the release remains a standalone Bash script.
set -eu
case "${1:-}" in
  -h|--help|help)
    printf '%s\n' '用法: sh install.sh [sb 命令及参数]' '默认进入菜单；例如 add --protocol reality --port 443 --sni www.python.org'
    exit 0 ;;
esac
[ "$(uname -s)" = Linux ] || { echo '仅支持 Linux' >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo '请使用 root 用户运行' >&2; exit 1; }
if ! command -v bash >/dev/null 2>&1; then
  case "${1:-}:${2:-}" in
    status:*|doctor:*|config:*|list:*|ls:*|info:*|log:*|logs:*|dns:show|route:show)
      echo '只读查询需要先安装 Bash' >&2; exit 1 ;;
  esac
  if command -v apk >/dev/null 2>&1; then apk add --no-cache bash ca-certificates
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash ca-certificates
  elif command -v dnf >/dev/null 2>&1; then dnf install -y bash ca-certificates
  elif command -v yum >/dev/null 2>&1; then yum install -y bash ca-certificates
  else echo '无法自动安装 Bash：未识别包管理器' >&2; exit 1; fi
fi
SCRIPT_URL=${SCRIPT_URL:-${GH_PROXY:-}https://github.com/Jonathan143/sb-install/releases/latest/download/sb.sh}
export SCRIPT_URL
sb_install_tmp=$(mktemp -d)
trap 'rm -rf "$sb_install_tmp"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --connect-timeout 15 --max-time 120 "$SCRIPT_URL" -o "$sb_install_tmp/sb.sh"
elif command -v wget >/dev/null 2>&1; then
  wget -T 30 -O "$sb_install_tmp/sb.sh" "$SCRIPT_URL"
else echo '需要 curl 或 wget 下载 Release' >&2; exit 1; fi
[ -s "$sb_install_tmp/sb.sh" ] || { echo '下载的脚本为空' >&2; exit 1; }
bash -n "$sb_install_tmp/sb.sh"
# A piped installer must read interactive prompts from the terminal.
if [ "$#" = 0 ] && [ ! -t 0 ]; then
  bash "$sb_install_tmp/sb.sh" < /dev/tty
else
  bash "$sb_install_tmp/sb.sh" "$@"
fi
