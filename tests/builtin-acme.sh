#!/usr/bin/env bash
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
SB_DIR="$ROOT"; CONF_DIR="$ROOT/conf.d"; META_DIR="$ROOT/meta"; SB_WORKDIR="$ROOT/work"
ACME_EMAIL=test@example.test
mkdir -p "$CONF_DIR" "$META_DIR"
core_version() { echo "$VERSION"; }
for VERSION in 1.12.0 1.13.0 1.14.0 1.16.0; do
  for proto in ws hy2 tuic anytls; do
    meta_reset
    N_ID=1 N_PROTO=$proto N_LPORT=24443 N_CERTMODE=builtin N_DOMAIN=example.test N_ACMEV=http
    N_UUID=00000000-0000-4000-8000-000000000001 N_PASS=test N_WSPATH=/test
    write_node_conf || fail "$VERSION $proto config"
    if version_ge "$VERSION" 1.14.0; then
      jq -e --arg data "$SB_WORKDIR/acme" '.inbounds[0].tls | (has("acme")|not) and
        .certificate_provider.type == "acme" and .certificate_provider.domain == ["example.test"] and
        .certificate_provider.data_directory == $data and .certificate_provider.email == "test@example.test" and
        .certificate_provider.disable_tls_alpn_challenge and (.certificate_provider.disable_http_challenge|not)' "$(conf_file)" >/dev/null || fail 'modern ACME schema'
    else
      jq -e '.inbounds[0].tls | .acme.domain == ["example.test"] and (has("certificate_provider")|not)' "$(conf_file)" >/dev/null || fail 'legacy compatibility'
    fi
  done
done
# Existing metadata is migrated in both directions without altering other files or caller state.
N_ACMEV=alpn
meta_save
printf '{"custom":true}\n' > "$CONF_DIR/custom.json"
printf '{"legacy":true}\n' > "$SB_DIR/config.json"
VERSION=1.14.0
N_ID=99 N_PROTO=ss
refresh_builtin_acme_configs || fail migration
[[ $N_ID == 99 && $N_PROTO == ss ]] || fail 'migration leaked node state'
jq -e '.inbounds[0].tls.certificate_provider.disable_http_challenge' "$CONF_DIR/01-anytls.json" >/dev/null || fail 'ALPN migration'
VERSION=1.12.0
refresh_builtin_acme_configs || fail downgrade
jq -e '.inbounds[0].tls.acme.disable_http_challenge' "$CONF_DIR/01-anytls.json" >/dev/null || fail 'ACME downgrade'
[[ $(cat "$CONF_DIR/custom.json") == '{"custom":true}' && $(cat "$SB_DIR/config.json") == '{"legacy":true}' ]] || fail 'unmanaged config rewritten'
echo 'PASS: builtin ACME provider migration and old-core compatibility'
