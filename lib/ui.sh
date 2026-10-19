#!/usr/bin/env bash
# Terminal presentation and input. Prompts use stderr so values remain pipe-safe.
RED=''; GREEN=''; YELLOW=''; CYAN=''; PLAIN=''; BOLD=''; DIM=''
if [[ -t 1 && -t 2 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'
  PLAIN=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
fi
info() { printf '%s[信息]%s %s\n' "$GREEN" "$PLAIN" "$*" >&2; }
warn() { printf '%s[警告]%s %s\n' "$YELLOW" "$PLAIN" "$*" >&2; }
err()  { printf '%s[错误]%s %s\n' "$RED" "$PLAIN" "$*" >&2; }
die()  { err "$*"; exit 1; }
ui_title() { printf '\n%s━━ %s ━━%s\n' "$BOLD$CYAN" "$*" "$PLAIN"; }
ui_section() { printf '\n%s%s%s\n' "$BOLD" "$*" "$PLAIN"; }
ui_item() { printf '  %s%2s%s  %s\n' "$CYAN" "$1" "$PLAIN" "$2"; }
ask() {
  local a
  printf '%s › %s%s: %s' "$CYAN" "$1" "${2:+ [$2]}" "$PLAIN" >&2
  IFS= read -r a || return 1
  printf '%s\n' "${a:-${2:-}}"
}
ask_secret() {
  local a rc=0
  printf ' › %s（输入隐藏）: ' "$1" >&2
  IFS= read -rs a || rc=$?
  printf '\n' >&2
  ((rc == 0)) || return "$rc"
  printf '%s\n' "$a"
}
confirm() {
  local def=${2:-y} hint='Y/n' a
  [[ $def != n ]] || hint='y/N'
  while true; do
    a=$(ask "$1 ($hint)" "$def") || return 1
    case $a in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) warn '请输入 y 或 n（回车使用默认值）' ;;
    esac
  done
}
# Validated menu selection; 0/q always returns to the caller.
ask_choice() {
  local value max=$2
  while true; do
    value=$(ask "$1" "${3:-}") || return 1
    case $value in 0|q|Q) printf '0\n'; return 0 ;; esac
    if [[ $value =~ ^[1-9][0-9]?$ ]] && ((value <= max)); then
      printf '%s\n' "$value"; return 0
    fi
    warn "请输入 1–${max}，或 0 返回"
  done
}
pause() {
  local reply
  [[ -t 0 ]] || return 0
  printf '\n%s按回车继续…%s' "$DIM" "$PLAIN" >&2
  IFS= read -r reply
}
