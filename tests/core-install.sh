#!/usr/bin/env bash
# Offline regression tests: real archives/files, mocked downloads and services.
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
get_arch() { echo amd64; }
uses_musl() { [[ $MUSL == yes ]]; }
latest_version() { echo 1.14.3; }
confirm() { return 0; }
write_service() { touch "$ROOT/service"; }
curl() {
  local dest url name version
  while (($#)); do
    if [[ $1 == -o ]]; then dest=$2; shift 2; else url=$1; shift; fi
  done
  echo "$url" >> "$ROOT/urls"
  [[ $MODE == download-failure ]] && return 22
  [[ $MODE == legacy && $url == *-musl.tar.gz ]] && return 22
  name=${url##*/}; name=${name%.tar.gz}
  version=${name#sing-box-}; version=${version%%-linux-*}
  rm -rf "$ROOT/fixture"
  mkdir -p "$ROOT/fixture/$name"
  if [[ $MODE == broken || ( $MODE == fallback && $url != *-musl.tar.gz ) ]]; then
    printf '#!/missing/sing-box-loader\n' > "$ROOT/fixture/$name/sing-box"
  elif [[ $MODE == invalid-output ]]; then
    printf '#!/bin/sh\necho unexpected\n' > "$ROOT/fixture/$name/sing-box"
  else
    printf '#!/bin/sh\necho "sing-box version %s"\n' "$version" > "$ROOT/fixture/$name/sing-box"
  fi
  chmod +x "$ROOT/fixture/$name/sing-box"
  tar -czf "$dest" -C "$ROOT/fixture" "$name"
}
reset_case() {
  rm -f "$ROOT/urls" "$ROOT/service"
  SB_BIN="$ROOT/bin/sing-box"
  mkdir -p "$ROOT/bin"
  printf '#!/bin/sh\necho "sing-box version 1.12.0"\n' > "$SB_BIN"
  chmod +x "$SB_BIN"
  MUSL=no; MODE=normal
}
reset_case
install_core 1.14.3 || fail 'normal install'
[[ $(core_version) == 1.14.3 ]] || fail 'version detection'
[[ $(wc -l < "$ROOT/urls") -eq 1 ]] || fail 'unnecessary fallback'
reset_case; MUSL=yes
install_core 1.14.3 || fail 'musl install'
[[ $(cat "$ROOT/urls") == *amd64-musl.tar.gz ]] || fail 'musl asset selection'
reset_case; MODE=fallback
install_core 1.14.3 || fail 'runtime fallback'
[[ $(wc -l < "$ROOT/urls") -eq 2 ]] || fail 'fallback not attempted'
reset_case; MUSL=yes; MODE=legacy
install_core 1.12.0 || fail 'legacy asset fallback'
for MODE in broken download-failure invalid-output; do
  if install_core 1.14.3 > "$ROOT/output" 2>&1; then fail "$MODE accepted"; fi
  [[ $(core_version) == 1.12.0 ]] || fail "$MODE replaced previous core"
  if grep -q '已安装:' "$ROOT/output"; then fail "$MODE reported success"; fi
done
reset_case
install() { return 1; }
if install_core 1.14.3; then fail 'write failure accepted'; fi
[[ $(core_version) == 1.12.0 ]] || fail 'write failure replaced core'
unset -f install
reset_case
printf '#!/missing/sing-box-loader\n' > "$SB_BIN"
if core_version >/dev/null; then fail 'broken core accepted'; fi
need_core || fail 'broken core repair'
[[ -f $ROOT/service && $(core_version) == 1.14.3 ]] || fail 'repair incomplete'
reset_case
need_core || fail 'healthy core rejected'
[[ ! -f $ROOT/urls ]] || fail 'healthy core reinstalled'
echo 'PASS: core installation regression tests'
