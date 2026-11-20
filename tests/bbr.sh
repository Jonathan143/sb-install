#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../sb.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
BBR_CONF="$root/conf.d/99-sb-bbr.conf"
cc=net.ipv4.tcp_congestion_control
fq=net.core.default_qdisc
printf 'cubic\n' > "$root/$cc"
printf 'fq_codel\n' > "$root/$fq"
uname() { echo Linux; }
modprobe() { return 1; } # Built-in kernel support needs no loadable module.
tc() { echo 'qdisc fq_codel 0: dev eth0 root'; }
sysctl() {
  case $1 in
    -n) case $2 in
          net.ipv4.tcp_available_congestion_control) echo 'reno cubic bbr' ;;
          net.ipv4.tcp_allowed_congestion_control) echo 'reno cubic' ;;
          *) cat "$root/$2" ;;
        esac ;;
    -w) [[ ${2#*=} != "${denied:-}" ]] || return 1
        printf '%s\n' "${2#*=}" > "$root/${2%%=*}" ;;
    *) return 1 ;;
  esac
}
acquire_lock() { echo 'unexpected lock' >&2; exit 1; }
bootstrap() { echo 'unexpected bootstrap' >&2; exit 1; }
main bbr show > "$root/show"
grep -q '未全部开启' "$root/show"
grep -q 'fq_codel.*eth0' "$root/show"
[[ ! -e $BBR_CONF ]]
mkdir -p "${BBR_CONF%/*}"
echo original > "$BBR_CONF"
denied=bbr
if bbr_enable; then exit 1; fi
[[ $(cat "$root/$fq") == fq_codel && $(cat "$root/$cc") == cubic && $(cat "$BBR_CONF") == original ]]
unset denied
bbr_enable
cmp "$BBR_CONF" <(printf '%s\n' "$fq=fq" "$cc=bbr")
bbr_enable
main bbr show > "$root/show"
grep -q '已开启' "$root/show"
grep -q 'fq_codel.*eth0' "$root/show"
uname() { echo Darwin; }
if bbr_enable; then exit 1; fi
echo 'PASS: BBR defaults, live queues, persistence and rollback'
