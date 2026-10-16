#!/usr/bin/env bash
# Offline HTTP fixtures; no credentials or DNS records are sent to external APIs.
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ZONE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ACCOUNT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
CF_Token=test-token-do-not-log
N_DOMAIN=www.example.co.uk
curl() {
  local url=${!#} arg config=no header body code=200
  for arg in "$@"; do
    [[ $arg != *"$CF_Token"* ]] || return 99
    [[ $arg != --config ]] || config=yes
  done
  printf '%s\n' "$url" >> "$ROOT/requests"
  [[ $MODE != network ]] || return 6
  if [[ $url == "$ACME_SERVER" ]]; then
    if [[ $MODE == bad-directory ]]; then echo '{}'; else
      echo '{"newNonce":"https://ca.test/nonce","newAccount":"https://ca.test/account","newOrder":"https://ca.test/order"}'
    fi
    return
  fi
  [[ $config == yes ]] || return 98
  IFS= read -r header
  [[ $header == "header = \"Authorization: Bearer $CF_Token\"" ]] || return 97
  body='{"success":true,"result":{"status":"active"}}'
  case $MODE in
    invalid) code=403; body='{"success":false,"errors":[{"code":1000}]}' ;;
    expired) body='{"success":true,"result":{"status":"expired"}}' ;;
    rate-limit) code=429; body='{}' ;;
    bad-json) body='<html>proxy</html>' ;;
    *)
      case $url in
        */user/tokens/verify)
          if [[ $MODE == account ]]; then code=401; body='{"success":false}'; fi ;;
        */accounts/*/tokens/verify) ;;
        *zones\?*)
          body='{"success":true,"result":[]}'
          if [[ $MODE == no-read ]]; then code=403; body='{"success":false}';
          elif [[ $url == *'name=example.co.uk'* && $MODE != no-zone ]]; then
            body="{\"success\":true,\"result\":[{\"id\":\"$ZONE\",\"name\":\"example.co.uk\",\"account\":{\"id\":\"$ACCOUNT\"}}]}"
          fi ;;
        *) return 96 ;;
      esac ;;
  esac
  printf '%s\n%s' "$body" "$code"
}
for MODE in normal account wildcard invalid expired rate-limit bad-json no-read no-zone network; do
  : > "$ROOT/requests"
  CF_Account_ID=""; CF_Zone_ID=stale
  N_DOMAIN=www.example.co.uk
  [[ $MODE != account ]] || CF_Account_ID=$ACCOUNT
  [[ $MODE != wildcard ]] || N_DOMAIN='*.example.co.uk'
  rc=0
  cf_preflight > "$ROOT/output" 2>&1 || rc=$?
  case $MODE in
    normal|account|wildcard)
      [[ $rc == 0 && $CF_Zone_ID == "$ZONE" && $CF_Account_ID == "$ACCOUNT" ]] || fail "$MODE zone detection"
      grep -q 'DNS 编辑权限将在' "$ROOT/output" || fail 'overstated permissions'
      if [[ $MODE == account ]]; then
        grep -q "/accounts/$ACCOUNT/tokens/verify" "$ROOT/requests" || fail 'account token endpoint missing'
      fi ;;
    *) [[ $rc != 0 && -z ${CF_Zone_ID:-} ]] || fail "$MODE accepted" ;;
  esac
  if grep -q "$CF_Token" "$ROOT/output"; then fail 'token leaked'; fi
done
MODE=normal; CF_Token=''; : > "$ROOT/requests"
if cf_preflight >/dev/null 2>&1; then fail 'empty token accepted'; fi
[[ ! -s $ROOT/requests ]] || fail 'empty token sent'
CF_Token=test-token-do-not-log
MODE=normal
acme_directory_check >/dev/null 2>&1 || fail 'valid CA rejected'
for MODE in network bad-directory; do
  if acme_directory_check >/dev/null 2>&1; then fail 'bad CA accepted'; fi
done
# Exercise cert_dns end-to-end using a fake acme.sh executable.
(
  CERT_DIR="$ROOT/certs"; N_DOMAIN=example.co.uk; ACME_SH="$ROOT/acme.sh"
  export TEST_ROOT="$ROOT"
  cat > "$ACME_SH" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/acme-args"
case $1 in
  --issue)
    [[ " $* " == *' --server https://acme-v02.api.letsencrypt.org/directory '* ]] || exit 99
    if [[ $ISSUE_RC == 12 ]]; then echo 'Cannot init API for invalid-directory'; exit 12; fi
    if [[ $ISSUE_RC == 13 ]]; then echo 'Add txt record error.'; exit 13; fi
    exit "${ISSUE_RC:-0}" ;;
  --install-cert)
    [[ ${INSTALL_FAIL:-0} != 1 ]] || exit 1
    while (($#)); do
      case $1 in --fullchain-file|--key-file) echo test > "$2"; shift ;; esac
      shift
    done ;;
esac
SCRIPT
  chmod +x "$ACME_SH"
  install_acme() { return 0; }
  acme_directory_check() { return 0; }
  ask() { case $1 in '请选择') echo 1 ;; *) echo '' ;; esac; }
  ask_secret() { echo test-token-do-not-log; }
  cert_expiry() { echo test-expiry; }
  MODE=normal
  for ISSUE_RC in 0 2 12 13; do
    export ISSUE_RC
    : > "$ROOT/acme-args"
    CF_Account_ID=stale
    rc=0
    cert_dns > "$ROOT/output" 2>&1 || rc=$?
    case $ISSUE_RC in
      0|2) [[ $rc == 0 && $N_CERTMODE == dns ]] || fail 'successful issuance rejected' ;;
      12|13)
        [[ $rc != 0 ]] || fail 'failed issuance accepted'
        if grep -q -- '--install-cert' "$ROOT/acme-args"; then fail 'installed after failure'; fi
        if [[ $ISSUE_RC == 12 ]]; then
          grep -q 'ACME CA 初始化失败' "$ROOT/output" || fail 'wrong CA diagnostic'
        else
          grep -q 'DNS 验证记录操作失败' "$ROOT/output" || fail 'wrong DNS diagnostic'
        fi ;;
    esac
  done
  MODE=normal; ISSUE_RC=0; export INSTALL_FAIL=1
  if cert_dns > "$ROOT/output" 2>&1; then fail 'install failure ignored'; fi
  grep -q '安装证书文件失败' "$ROOT/output" || fail 'wrong install diagnostic'
  unset INSTALL_FAIL
  MODE=invalid; : > "$ROOT/acme-args"
  if cert_dns < /dev/null >/dev/null 2>&1; then fail 'issuance accepted invalid token'; fi
  [[ ! -s $ROOT/acme-args ]] || fail 'acme called with invalid token'
  if cert_dns <<< q > /dev/null 2>&1; then fail 'cancel ignored'; fi
  [[ ! -s $ROOT/acme-args ]] || fail 'acme called after cancellation'
  # First attempt gets an HTTP error; Enter retries credentials in the same flow.
  ask_secret() {
    echo attempt >> "$ROOT/token-attempts"
    echo test-token-do-not-log
  }
  curl() {
    local body code
    if [[ $(wc -l < "$ROOT/token-attempts") -eq 1 ]]; then
      body='{"success":false}'; code=401
    elif [[ ${!#} == */user/tokens/verify ]]; then
      body='{"success":true,"result":{"status":"active"}}'; code=200
    else
      body="{\"success\":true,\"result\":[{\"id\":\"$ZONE\",\"name\":\"example.co.uk\",\"account\":{\"id\":\"$ACCOUNT\"}}]}"; code=200
    fi
    printf '%s\n%s' "$body" "$code"
  }
  cert_dns <<< '' > "$ROOT/output" 2>&1 || fail 'retry did not complete issuance'
  [[ $(wc -l < "$ROOT/token-attempts") -eq 2 ]] || fail 'credentials not requested again'
  grep -q 'HTTP 401' "$ROOT/output" || fail 'missing first failure'
  grep -q -- '--install-cert' "$ROOT/acme-args" || fail 'retry did not install certificate'
) || exit 1
echo 'PASS: ACME and Cloudflare preflight regression tests'
