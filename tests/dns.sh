#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
SB_RESOLV_CONF="$ROOT/resolv.conf"
SB_DNS_BACKUP="$ROOT/backup"
# Avoid inspecting the host's resolver daemon.
resolvectl() { :; }
for ip in 1.1.1.1 8.8.8.8 0.0.0.0 255.255.255.255 ::1 :: 2606:4700:4700::1111 1:2:3:4:5:6:7:8; do
  system_dns_valid_ip "$ip" || fail "valid IP: $ip"
done
for ip in '' example.com 256.1.1.1 1.2.3 01.2.3.4 '1.1.1.1;echo' 1:2:3 ::1: :1:: 1::2::3 1:2:3:4:5:6:7:8:9 12345::1 fe80::1%eth0; do
  if system_dns_valid_ip "$ip"; then fail "invalid IP: $ip"; fi
done
printf 'search example.test\noptions timeout:2\nnameserver 9.9.9.9\n' > "$ROOT/original"
cp "$ROOT/original" "$SB_RESOLV_CONF"
if system_dns_set bad; then fail 'accepted invalid input'; fi
[[ ! -e $SB_DNS_BACKUP ]] || fail 'invalid input created backup'
system_dns_set 1.1.1.1 8.8.8.8
cmp "$ROOT/original" "$SB_DNS_BACKUP" || fail backup
grep -q '^search example.test$' "$SB_RESOLV_CONF" || fail search
grep -q '^options timeout:2$' "$SB_RESOLV_CONF" || fail options
[[ $(grep -c '^nameserver ' "$SB_RESOLV_CONF") == 2 ]] || fail servers
system_dns_set 2606:4700:4700::1111
cmp "$ROOT/original" "$SB_DNS_BACKUP" || fail 'backup overwritten'
system_dns_restore
cmp "$ROOT/original" "$SB_RESOLV_CONF" || fail restore
rm "$SB_RESOLV_CONF"
ln -s "$ROOT/original" "$SB_RESOLV_CONF"
system_dns_set 8.8.8.8
[[ ! -L $SB_RESOLV_CONF && -L $SB_DNS_BACKUP ]] || fail 'symlink takeover'
grep -q '9.9.9.9' "$ROOT/original" || fail 'changed link target'
system_dns_restore
[[ -L $SB_RESOLV_CONF ]] || fail 'symlink restore'
# Cancellation and EOF must never change the resolver.
system_dns_menu <<< $'1\nn'
system_dns_menu < /dev/null
system_dns_menu <<< $'4\n0'
[[ -L $SB_RESOLV_CONF && ! -e $SB_DNS_BACKUP ]] || fail cancellation
# DNS CLI dispatch must work without bootstrap/network dependency installation.
acquire_lock() { :; }
bootstrap() { fail 'DNS called bootstrap'; }
if [[ $EUID == 0 ]]; then main dns show; fi
printf 'PASS: DNS validation, backup, restore, symlinks and cancellation\n'
