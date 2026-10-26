#!/usr/bin/env bash
# Offline SNI regression tests: no public network requests or node changes.
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The quick set is a curated subset; every built-in domain has display metadata.
(
  [[ ${#SNI_LIST[@]} == 26 && ${#SNI_QUICK_LIST[@]} == 10 ]] || fail 'candidate counts'
  [[ $(printf '%s\n' "${SNI_LIST[@]}" | sort -u | wc -l) -eq 26 ]] || fail 'duplicate catalog domain'
  [[ $(printf '%s\n' "${SNI_QUICK_LIST[@]}" | sort -u | wc -l) -eq 10 ]] || fail 'duplicate quick domain'
  for domain in "${SNI_LIST[@]}"; do
    sni_valid_domain "$domain" || fail "invalid catalog domain: $domain"
    sni_domain_info "$domain"
    [[ -n $SNI_CATEGORY && $SNI_CATEGORY != 自定义域名 ]] || fail "missing category: $domain"
  done
  for domain in "${SNI_QUICK_LIST[@]}"; do
    [[ " ${SNI_LIST[*]} " == *" $domain "* ]] || fail "quick domain missing from catalog: $domain"
  done
  for domain in www.u-tokyo.ac.jp www.nus.edu.sg www.stanford.edu www.ox.ac.uk \
    dl-cdn.alpinelinux.org www.python.org pypi.org addons.mozilla.org \
    www.lovelive-anime.jp www.cathaypacific.com; do
    [[ " ${SNI_QUICK_LIST[*]} " == *" $domain "* ]] || fail "missing agreed quick domain: $domain"
  done
  sni_domain_info www.u-tokyo.ac.jp
  [[ $SNI_CATEGORY == 日本高校 ]] || fail 'university category'
  sni_domain_info cpan.org
  [[ $SNI_CATEGORY == 'Perl 包仓库' ]] || fail 'package repository category'
  sni_domain_info custom.example
  [[ $SNI_CATEGORY == 自定义域名 ]] || fail 'unknown domain retained stale category'
) || exit 1

# BusyBox timeout being present must not suppress the GNU dependency install.
(
  detect_pkg() { PKG=apk; }
  curl() { :; }; jq() { :; }; openssl() { :; }; tar() { :; }
  ss() { :; }; qrencode() { :; }
  timeout() {
    [[ $1 == --version ]] || fail 'unexpected timeout invocation'
    [[ -f $ROOT/gnu-installed ]] || { echo 'BusyBox timeout'; return 1; }
    echo 'timeout (GNU coreutils) test'
  }
  pkg_install() {
    [[ $* == 'ca-certificates coreutils' ]] || fail 'wrong timeout dependency'
    touch "$ROOT/gnu-installed"
  }
  if has_gnu_timeout; then fail 'accepted BusyBox timeout'; fi
  install_deps || fail 'GNU timeout installation'
  has_gnu_timeout || fail 'GNU timeout not rechecked'
  pkg_install() { fail 'reinstalled existing GNU timeout'; }
  install_deps || fail 'existing GNU timeout rejected'
) || exit 1

# Validate handshake requirements and reject success-looking output on failure.
(
  timeout() {
    [[ $1 == -k && $2 == 1 ]] || fail 'missing hard timeout'
    shift 2
    [[ $1 == 2 || $1 == 8 ]] || fail 'wrong timeout'
    shift; "$@"
  }
  openssl() {
    [[ $* == 's_client -connect test.example:443 -servername test.example -tls1_3 -alpn h2 -verify_hostname test.example -verify_return_error' ]] || return 99
    [[ $MODE == tls12 ]] && echo 'TLSv1.2' || echo 'New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384'
    [[ $MODE == no-h2 ]] || echo 'ALPN protocol: h2'
    [[ $MODE == bad-cert ]] || echo 'Verify return code: 0 (ok)'
    # HTTP/2 SETTINGS frames can arrive without an HTTP request.
    printf '\000\000\000\004\000\000\000\000\000'
    case $MODE in timeout) return 124 ;; killed) return 137 ;; terminated) return 143 ;; failure) return 1 ;; esac
    return 0
  }
  MODE=ok; check_sni test.example 2 2> "$ROOT/handshake-stderr" || fail 'valid handshake rejected'
  [[ ! -s $ROOT/handshake-stderr ]] || fail 'binary handshake emitted a warning'
  for MODE in tls12 no-h2 bad-cert timeout killed terminated failure; do
    if check_sni test.example 2> "$ROOT/handshake-stderr"; then fail "$MODE handshake accepted"; fi
    [[ ! -s $ROOT/handshake-stderr ]] || fail 'binary failure emitted a warning'
    [[ -n $SNI_FAILURE ]] || fail 'missing failure reason'
    case $MODE in timeout|killed|terminated) [[ $SNI_FAILURE == 超时 ]] || fail 'timeout status lost in pipeline' ;; esac
  done
) || exit 1

# Exercise the real timeout against a child that ignores TERM (Linux CI).
if has_gnu_timeout; then
  (
    mkdir -p "$ROOT/bin"
    cat > "$ROOT/bin/openssl" <<'STUB'
#!/bin/sh
trap '' TERM
exec sleep 30
STUB
    chmod +x "$ROOT/bin/openssl"
    PATH="$ROOT/bin:$PATH"
    SECONDS=0
    if check_sni test.example 1; then fail 'hanging handshake accepted'; fi
    [[ $SNI_FAILURE == 超时 ]] || fail 'hard timeout status'
    ((SECONDS <= 6)) || fail 'hard timeout did not bound handshake'
  ) || exit 1
else
  echo 'SKIP: real hard-timeout integration requires GNU timeout (runs in Linux CI)'
fi

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

# A small cgroup must downgrade or stop before spawning probe workers.
(
  sni_pid_budget() { SNI_PID_AVAILABLE=$available; }
  available=24; sni_limit_concurrency 4 || fail 'ample budget'
  [[ $SNI_EFFECTIVE_CONCURRENCY == 4 ]] || fail 'unnecessary downgrade'
  available=12; sni_limit_concurrency 4 || fail 'serial budget'
  [[ $SNI_EFFECTIVE_CONCURRENCY == 1 ]] || fail 'missing downgrade'
  available=4
  if sni_limit_concurrency 1; then fail 'exhausted budget accepted'; fi
  sni_measure() { fail 'exhausted scan started worker'; }
  if sni_scan; then fail 'exhausted scan started'; fi
) || exit 1

# Both serial and parallel collection deduplicate and include the current SNI.
unset SNI_CONCURRENCY SNI_SCAN_MODE
[[ $(sni_concurrency) == 4 ]] || fail 'default concurrency'
for invalid in 0 5 -1 bogus; do
  [[ $(SNI_CONCURRENCY=$invalid sni_concurrency) == 4 ]] || fail 'invalid concurrency'
done
# Prompt validation, default, cancellation, and EOF must happen before scanning.
[[ $(sni_ask_concurrency <<< '') == 4 ]] || fail 'prompt default'
[[ $(sni_ask_concurrency <<< $'5\nbad\n2') == 2 ]] || fail 'prompt validation'
for input in 0 q; do
  if sni_ask_concurrency <<< "$input"; then fail 'prompt cancellation'; fi
done
if sni_ask_concurrency < /dev/null; then fail 'prompt EOF'; fi
[[ $(sni_ask_mode <<< '') == quick ]] || fail 'default quick mode'
[[ $(sni_ask_mode <<< $'bad\n3\n2') == all ]] || fail 'mode validation'
[[ $(SNI_SCAN_MODE=all sni_ask_mode <<< '') == all ]] || fail 'remember selected mode'
for input in 0 q; do
  if sni_ask_mode <<< "$input"; then fail 'mode cancellation'; fi
done
if sni_ask_mode < /dev/null; then fail 'mode EOF'; fi
(
  timeout() { echo 'timeout (GNU coreutils) test'; }
  sni_now_ms() { echo 1000; }
  sni_scan() {
    echo "$SNI_SCAN_MODE:$SNI_CONCURRENCY" >> "$ROOT/standalone-scans"
    [[ -z $N_SNI ]] || fail 'standalone included a node SNI'
    printf '3\t20\tfast.example\t通过\n'
  }
  N_SNI=stale.example
  sni_test <<< $'\n\n0' > /dev/null
  sni_test <<< $'2\n2\nr\ns\n1\n3\n0' > /dev/null
  sni_test <<< q > /dev/null
  [[ $UI_SKIP_PAUSE == 1 ]] || fail 'cancel paused'
  sni_test <<< $'1\nq' > /dev/null
  sni_test <<< 1 > /dev/null
  sni_test < /dev/null > /dev/null
  [[ $(cat "$ROOT/standalone-scans") == $'quick:4\nall:2\nall:2\nquick:3' ]] || fail 'standalone prompt dispatch'
  [[ $N_SNI == stale.example && -z ${SNI_SCAN_MODE:-} ]] || fail 'standalone leaked scan state'
) || exit 1

# Real scan dispatch uses the selected scope and only appends an absent current SNI.
(
  SNI_CONCURRENCY=4
  sni_measure() { printf '3\t20\t%s\t通过\n' "$1"; }
  for mode in quick all; do
    SNI_SCAN_MODE=$mode
    [[ $mode != quick ]] || expected=10
    [[ $mode != all ]] || expected=26
    for N_SNI in '' www.u-tokyo.ac.jp custom.example; do
      count=$expected
      [[ $N_SNI != custom.example ]] || count=$((count + 1))
      result=$(sni_scan 2> "$ROOT/scope-progress") || fail 'scope scan'
      [[ $(wc -l <<< "$result") -eq $count ]] || fail "wrong scope count: $mode/$N_SNI"
      [[ $result == *www.u-tokyo.ac.jp* ]] || fail 'missing quick university'
      if [[ $mode == quick ]]; then
        [[ $result != *www.kyoto-u.ac.jp* ]] || fail 'quick scan included all-only domain'
      else
        [[ $result == *www.kyoto-u.ac.jp* && $result == *$'\tcpan.org\t'* && $result == *$'\twww.cpan.org\t'* ]] || fail 'full scan missed candidates'
      fi
      grep -q '\[日本高校\]' "$ROOT/scope-progress" || fail 'progress category missing'
      awk -F '\t' 'NF != 4 { exit 1 }' <<< "$result" || fail 'metadata leaked into TSV'
    done
  done
  sni_show_results "$result" > "$ROOT/results"
  grep -q '本轮最快.*当前.*\[日本高校\]\|\[日本高校\]' "$ROOT/results" || fail 'result category missing'
  grep -q '\[自定义域名\]' "$ROOT/results" || fail 'custom result category missing'
  sni_measure() { fail 'invalid scope started a probe'; }
  SNI_SCAN_MODE=bad
  if sni_scan; then fail 'accepted invalid scope'; fi
) || exit 1

(
  sni_progress www.u-tokyo.ac.jp 3 20 通过 2> "$ROOT/completed-progress"
  grep -q '\[日本高校\].*3/3.*通过' "$ROOT/completed-progress" || fail 'completed progress category missing'
) || exit 1

for concurrency in 1 4; do
(
  SNI_CONCURRENCY=$concurrency
  SNI_SCAN_MODE=all
  SNI_LIST=(slow.example partial.example failed.example fast.example slow.example)
  N_SNI=current.example
  sni_measure() {
    echo "$1" >> "$ROOT/probed"
    echo "$BASH_SUBSHELL" >> "$ROOT/workers"
    case $1 in
      slow.example) printf '3\t90\t%s\t通过\n' "$1" ;;
      fast.example|current.example) printf '3\t20\t%s\t通过\n' "$1" ;;
      partial.example) printf '2\t1\t%s\t不稳定\n' "$1" ;;
      failed.example) printf '0\t0\t%s\t超时\n' "$1" ;;
    esac
  }
  TMPDIR="$ROOT"
  before=$(ls -A "$ROOT")
  expected_depth=$((BASH_SUBSHELL + 2))
  ((concurrency == 1)) || expected_depth=$((expected_depth + 1))
  result=$(sni_scan) || fail 'scan failed'
  order=$(printf '%s\n' "$result" | cut -f3 | tr '\n' ' ')
  [[ $order == 'current.example fast.example slow.example partial.example failed.example ' ]] || fail "ranking: $order"
  [[ $(wc -l < "$ROOT/probed") -eq 5 ]] || fail 'missing domain or duplicate probe'
  [[ $(sort -u "$ROOT/workers") == "$expected_depth" ]] || fail 'unexpected worker subshell depth'
  rm "$ROOT/probed" "$ROOT/workers"
  [[ $(ls -A "$ROOT") == "$before" ]] || fail 'scan left temporary files'
  sni_measure() { echo failed >> "$ROOT/failed-workers"; return 1; }
  if sni_scan; then fail 'worker failure ignored'; fi
  [[ $(wc -l < "$ROOT/failed-workers") -eq $concurrency ]] || fail 'scan continued after worker failure'
  rm "$ROOT/failed-workers"
  [[ $(ls -A "$ROOT") == "$before" ]] || fail 'failed scan left temporary files'
) || exit 1

done

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
  timeout() { echo 'timeout (GNU coreutils) test'; }
  sni_now_ms() { echo 1000; }
  sni_scan() {
    if [[ $scenario == retest ]]; then
      [[ $SNI_CONCURRENCY == 2 ]] || fail 'retest lost selected concurrency'
      [[ $SNI_SCAN_MODE == all ]] || fail 'retest lost selected scope'
    else
      [[ $SNI_CONCURRENCY == 4 ]] || fail 'picker default concurrency'
    fi
    echo "$SNI_SCAN_MODE" >> "$ROOT/scans"
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
    default) input=$'\n\n\n\n' ;;
    second) input=$'1\n\n\n02\n' ;;
    invalid) input=$'1\n\n\n3\n9999999999999999999\n08\n1\n' ;;
    retest) input=$'1\n2\n2\nr\n1\n' ;;
    all) input=$'1\n2\n\n1\n' ;;
    switch) input=$'1\n\n\ns\n2\n\n1\n' ;;
    manual) input=$'2\nhttps://example.com\nCUSTOM.EXAMPLE\n' ;;
    manual-index) input=$'2\n02\n' ;;
    manual-failed) input=$'2\ncustom.example\nn\n0\n' ;;
    manual-override) input=$'2\ncustom.example\ny\n' ;;
    all-failed) input=$'1\n\n\n\n0\n' ;;
    cancel) input=$'0\n' ;;
    cancel-scope) input=$'1\nq\n' ;;
    cancel-concurrency) input=$'1\n2\nq\n' ;;
    eof-scope) input=$'1\n' ;;
    eof-concurrency) input=$'1\n2\n' ;;
    eof) input='' ;;
  esac
  printf '%s' "$input" > "$ROOT/input"
  pick_sni < "$ROOT/input" > "$ROOT/output" 2>&1 || rc=$?
  case $scenario in
    cancel*|eof*|all-failed|manual-failed)
      [[ $rc != 0 && -z $PICKED ]] || fail "$scenario chose $PICKED" ;;
    *) [[ $rc == 0 ]] || fail "$scenario failed" ;;
  esac
  case $scenario in
    default|invalid|retest|manual-index|all|switch) [[ $PICKED == fast.example ]] || fail "$scenario chose $PICKED" ;;
    second) [[ $PICKED == slow.example ]] || fail 'ranking index mapped to original list' ;;
    manual|manual-override) [[ $PICKED == custom.example ]] || fail 'custom domain not normalized' ;;
  esac
  case $scenario in
    default) [[ $(cat "$ROOT/scans") == quick ]] || fail 'picker default scope' ;;
    all) [[ $(cat "$ROOT/scans") == all ]] || fail 'picker full scope' ;;
    retest) [[ $(cat "$ROOT/scans") == $'all\nall' ]] || fail 'missing retest' ;;
    switch) [[ $(cat "$ROOT/scans") == $'quick\nall' ]] || fail 'scope switch' ;;
    cancel*|eof*) [[ ! -f $ROOT/scans && ! -f $ROOT/manual ]] || fail 'cancelled picker started a probe' ;;
  esac
  if [[ $scenario == default ]]; then grep -q '当前' "$ROOT/output" || fail 'current SNI not marked'; fi
  if [[ $scenario == manual ]]; then [[ $(cat "$ROOT/manual") == custom.example ]] || fail 'invalid domain probed'; fi
)
for scenario in default second invalid retest all switch manual manual-index manual-failed manual-override all-failed cancel cancel-scope cancel-concurrency eof eof-scope eof-concurrency; do
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
