#!/usr/bin/env bash
# Offline SNI regression tests: no public network requests or node changes.
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Validate handshake requirements and reject success-looking output on failure.
(
  timeout() {
    [[ $1 == 2 || $1 == 8 ]] || fail 'wrong timeout'
    shift; "$@"
  }
  openssl() {
    [[ $* == 's_client -connect test.example:443 -servername test.example -tls1_3 -alpn h2 -verify_hostname test.example -verify_return_error' ]] || return 99
    [[ $MODE == tls12 ]] && echo 'TLSv1.2' || echo 'New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384'
    [[ $MODE == no-h2 ]] || echo 'ALPN protocol: h2'
    [[ $MODE == bad-cert ]] || echo 'Verify return code: 0 (ok)'
    case $MODE in timeout) return 124 ;; failure) return 1 ;; esac
    return 0
  }
  MODE=ok; check_sni test.example 2 || fail 'valid handshake rejected'
  for MODE in tls12 no-h2 bad-cert timeout failure; do
    if check_sni test.example; then fail "$MODE handshake accepted"; fi
    [[ -n $SNI_FAILURE ]] || fail 'missing failure reason'
  done
) || exit 1

# Measurements use successful rounds only, without promoting partial success.
(
  sni_now_ms() {
    local tick=1000
    [[ ! -f $ROOT/tick ]] || read -r tick < "$ROOT/tick"
    echo "$((tick + 25))" > "$ROOT/tick"
    echo "$tick"
  }
  check_sni() {
    count=$((count + 1))
    [[ $2 == 2 ]] || fail 'measurement timeout'
    if [[ $MODE == failed || ( $MODE == partial && $count == 2 ) ]]; then
      SNI_FAILURE=超时; return 1
    fi
    return 0
  }
  MODE=ok; count=0
  result=$(sni_measure test.example)
  [[ $result == $'3\t25\ttest.example\t通过' ]] || fail "stable measurement: $result"
  MODE=partial; count=0
  result=$(sni_measure test.example)
  [[ $result == $'2\t25\ttest.example\t不稳定 (超时)' ]] || fail "partial measurement: $result"
  MODE=failed; count=0
  result=$(sni_measure test.example)
  [[ $result == $'0\t0\ttest.example\t超时' ]] || fail "failed measurement: $result"
) || exit 1

# Real background collection/sort: deduplicate and include the current SNI.
(
  SNI_LIST=(slow.example partial.example failed.example fast.example slow.example)
  N_SNI=current.example
  sni_measure() {
    echo "$1" >> "$ROOT/probed"
    case $1 in
      slow.example) printf '3\t90\t%s\t通过\n' "$1" ;;
      fast.example|current.example) printf '3\t20\t%s\t通过\n' "$1" ;;
      partial.example) printf '2\t1\t%s\t不稳定\n' "$1" ;;
      failed.example) printf '0\t0\t%s\t超时\n' "$1" ;;
    esac
  }
  TMPDIR="$ROOT"
  before=$(ls -A "$ROOT")
  result=$(sni_scan) || fail 'scan failed'
  order=$(printf '%s\n' "$result" | cut -f3 | tr '\n' ' ')
  [[ $order == 'current.example fast.example slow.example partial.example failed.example ' ]] || fail "ranking: $order"
  [[ $(wc -l < "$ROOT/probed") -eq 5 ]] || fail 'missing domain or duplicate probe'
  rm "$ROOT/probed"
  [[ $(ls -A "$ROOT") == "$before" ]] || fail 'scan left temporary files'
  sni_measure() { return 1; }
  if sni_scan; then fail 'worker failure ignored'; fi
  [[ $(ls -A "$ROOT") == "$before" ]] || fail 'failed scan left temporary files'
) || exit 1

for domain in www.example.com EXAMPLE.com a-b.example; do
  sni_valid_domain "$domain" || fail "valid domain: $domain"
done
for domain in '' 123 127.0.0.1 'https://example.com' 'example.com:443' 'a..com' '-a.com' 'a-.com' 'a.com.' '.a.com' 'a b.com'; do
  if sni_valid_domain "$domain"; then fail "invalid domain: $domain"; fi
done

# User flows: default/reordered selection, retest, manual validation, EOF/cancel.
run_pick() (
  local scenario=$1 rc=0
  SNI_LIST=(slow.example fast.example)
  N_SNI=slow.example
  PICKED=stale.example
  timeout() { :; }
  sni_now_ms() { echo 1000; }
  sni_scan() {
    echo scan >> "$ROOT/scans"
    if [[ $scenario == all-failed ]]; then
      printf '0\t0\tfailed.example\t超时\n'
    else
      printf '3\t20\tfast.example\t通过\n3\t90\tslow.example\t通过\n2\t1\tpartial.example\t不稳定\n'
    fi
  }
  check_sni() {
    echo "$1" >> "$ROOT/manual"
    SNI_FAILURE=超时
    [[ $scenario != manual-failed && $scenario != manual-override ]]
  }
  rm -f "$ROOT/scans" "$ROOT/manual"
  case $scenario in
    default) input=$'\n\n' ;;
    second) input=$'1\n02\n' ;;
    invalid) input=$'1\n3\n9999999999999999999\n08\n1\n' ;;
    retest) input=$'1\nr\n1\n' ;;
    manual) input=$'2\nhttps://example.com\nCUSTOM.EXAMPLE\n' ;;
    manual-index) input=$'2\n02\n' ;;
    manual-failed) input=$'2\ncustom.example\nn\n0\n' ;;
    manual-override) input=$'2\ncustom.example\ny\n' ;;
    all-failed) input=$'1\n\n0\n' ;;
    cancel) input=$'0\n' ;;
    eof) input='' ;;
  esac
  printf '%s' "$input" > "$ROOT/input"
  pick_sni < "$ROOT/input" > "$ROOT/output" 2>&1 || rc=$?
  case $scenario in
    cancel|eof|all-failed|manual-failed)
      [[ $rc != 0 && -z $PICKED ]] || fail "$scenario chose $PICKED" ;;
    *) [[ $rc == 0 ]] || fail "$scenario failed" ;;
  esac
  case $scenario in
    default|invalid|retest|manual-index) [[ $PICKED == fast.example ]] || fail "$scenario chose $PICKED" ;;
    second) [[ $PICKED == slow.example ]] || fail 'ranking index mapped to original list' ;;
    manual|manual-override) [[ $PICKED == custom.example ]] || fail 'custom domain not normalized' ;;
  esac
  if [[ $scenario == retest ]]; then [[ $(wc -l < "$ROOT/scans") -eq 2 ]] || fail 'missing retest'; fi
  if [[ $scenario == default ]]; then grep -q '当前' "$ROOT/output" || fail 'current SNI not marked'; fi
  if [[ $scenario == manual ]]; then [[ $(cat "$ROOT/manual") == custom.example ]] || fail 'invalid domain probed'; fi
)
for scenario in default second invalid retest manual manual-index manual-failed manual-override all-failed cancel eof; do
  run_pick "$scenario" || exit 1
done

# Cancelling an edit must not reuse PICKED or persist/regenerate the node.
(
  select_node() { SEL_ID=1; }
  meta_load() { N_ID=1; N_PROTO=reality; N_SNI=original.example; }
  snapshot() { :; }
  ask() { echo 2; }
  pick_sni() { PICKED=stale.example; return 1; }
  meta_save() { fail 'cancelled edit saved metadata'; }
  write_node_conf() { fail 'cancelled edit generated config'; }
  apply_config() { fail 'cancelled edit applied config'; }
  if edit_node 1 > "$ROOT/output" 2>&1; then fail 'cancelled edit succeeded'; fi
  [[ $N_SNI == original.example ]] || fail 'cancelled edit changed SNI'
) || exit 1
echo 'PASS: SNI selection regression tests'
