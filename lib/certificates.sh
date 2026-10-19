#!/usr/bin/env bash
# Source module; loaded by sb.sh.
#---------------------------------------------------------------------
# 证书
#---------------------------------------------------------------------
ask_domain() { # 提示
  local d
  while true; do
    d=$(ask "$1") || return 1; d=${d,,}
    [[ $d =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]] && { echo "$d"; return; }
    warn "域名格式不正确"
  done
}
cert_valid() { openssl x509 -checkend 2592000 -noout -in "$1" >/dev/null 2>&1; }
cert_expiry() { openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2; }
reload_cmd() { echo "systemctl restart $SB_SERVICE >/dev/null 2>&1 || rc-service $SB_SERVICE restart >/dev/null 2>&1 || true"; }

ask_acme_email() {
  if [[ -z $ACME_EMAIL ]]; then
    ACME_EMAIL=$(ask "ACME 账户邮箱（可留空）") || return 1
    save_conf
  fi
}

install_acme() {
  [[ -x $ACME_SH ]] && return 0
  info "安装 acme.sh ..."
  if ! command -v crontab >/dev/null; then
    detect_pkg
    case $PKG in apt) pkg_install cron ;; dnf|yum) pkg_install cronie ;; esac >/dev/null 2>&1
    has_systemd && { systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1; }
  fi
  ask_acme_email || return 1
  curl -fsSL https://get.acme.sh | sh -s ${ACME_EMAIL:+email="$ACME_EMAIL"} >/dev/null 2>&1
  [[ -x $ACME_SH ]] || { err "acme.sh 安装失败，请检查网络"; return 1; }
  "$ACME_SH" --set-default-ca --server "$ACME_SERVER" >/dev/null 2>&1 || {
    err "设置 ACME 默认 CA 失败"; return 1;
  }
}


acme_directory_check() {
  local response
  info "检查 ACME CA 连接..."
  if ! response=$(curl -fsS --connect-timeout 10 --max-time 20 "$ACME_SERVER" 2>/dev/null); then
    err "无法连接 ACME CA，请检查服务器网络、DNS、系统时间和 TLS 信任；此步骤与 DNS Token 无关"
    return 1
  fi
  if ! jq -e 'all(.newNonce, .newAccount, .newOrder; type == "string" and startswith("https://"))' \
       >/dev/null 2>&1 <<< "$response"; then
    err "ACME CA 返回了无效目录，请检查 CA 地址或网络代理；尚未开始 DNS 验证"
    return 1
  fi
}

# Keep the token out of curl argv and never print API response bodies.
cf_api_get() {
  local raw
  if ! raw=$(printf 'header = "Authorization: Bearer %s"\n' "$CF_Token" |
      curl -sS --config - --connect-timeout 10 --max-time 20 \
        --write-out '\n%{http_code}' "https://api.cloudflare.com/client/v4/$1" 2>/dev/null); then
    err "无法连接 Cloudflare API，请检查网络、DNS 和 TLS；尚不能判断 Token 是否有效"
    return 1
  fi
  CF_HTTP=${raw##*$'\n'}
  CF_RESPONSE=${raw%$'\n'*}
  if [[ $CF_HTTP == 429 || $CF_HTTP == 5* ]]; then
    err "Cloudflare API 暂时不可用或限流（HTTP $CF_HTTP），请稍后重试"
    return 1
  fi
  jq -e 'type == "object" and (.success | type == "boolean")' \
    >/dev/null 2>&1 <<< "$CF_RESPONSE" || { err "Cloudflare API 返回了无效响应"; return 1; }
}
cf_api_ok() { [[ $CF_HTTP == 200 ]] && jq -e '.success == true' >/dev/null <<< "$CF_RESPONSE"; }

cf_preflight() {
  local domain zone id account query status
  [[ ${CF_Token:-} =~ ^[A-Za-z0-9._-]+$ ]] || { err "CF_Token 不能为空，且不能包含空白或引号"; return 1; }
  [[ -z ${CF_Account_ID:-} || $CF_Account_ID =~ ^[a-fA-F0-9]{32}$ ]] || { err "CF_Account_ID 应为 32 位十六进制账户 ID"; return 1; }
  # Do not reuse a zone from a previous node or acme.sh's saved account config.
  unset CF_Zone_ID
  info "验证 Cloudflare API Token..."
  cf_api_get user/tokens/verify || return 1
  if ! cf_api_ok && [[ -n ${CF_Account_ID:-} ]]; then
    cf_api_get "accounts/$CF_Account_ID/tokens/verify" || return 1
  fi
  if ! cf_api_ok; then
    err "Cloudflare Token 验证失败（HTTP ${CF_HTTP}）：请检查 Token、有效期和来源 IP 限制；账户级 Token 还需填写 Account ID"
    return 1
  fi
  status=$(jq -r '.result.status // empty' <<< "$CF_RESPONSE")
  [[ $status == active ]] || { err "Cloudflare Token 未处于 active 状态（可能已禁用或过期）"; return 1; }
  domain=${N_DOMAIN#\*.}; domain=${domain%.}
  domain=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
  zone=$domain
  while [[ $zone == *.* ]]; do
    query="zones?name=$(urlenc "$zone")"
    [[ -z ${CF_Account_ID:-} ]] || query+="&account.id=$CF_Account_ID"
    cf_api_get "$query" || return 1
    cf_api_ok || { err "Token 有效，但无法查询 Zone，请检查 Zone-Zone-Read 权限及账户范围（HTTP $CF_HTTP）"; return 1; }
    jq -e '.result | type == "array"' >/dev/null <<< "$CF_RESPONSE" || { err "Cloudflare Zone 响应格式异常"; return 1; }
    id=$(jq -r --arg zone "$zone" '.result[] | select(.name == $zone) | .id' <<< "$CF_RESPONSE")
    if [[ -n $id ]]; then
      [[ $id =~ ^[a-fA-F0-9]{32}$ ]] || { err "Cloudflare Zone ID 异常或匹配不唯一"; return 1; }
      account=$(jq -r --arg id "$id" '.result[] | select(.id == $id) | .account.id // empty' <<< "$CF_RESPONSE")
      [[ $account =~ ^[a-fA-F0-9]{32}$ && ( -z ${CF_Account_ID:-} || $account == "$CF_Account_ID" ) ]] || { err "Cloudflare Zone 所属账户与 Account ID 不匹配"; return 1; }
      export CF_Zone_ID=$id CF_Account_ID=$account
      info "Token 有效，已确认目标 Zone: $zone"
      info "预检查未修改 DNS；DNS 编辑权限将在 acme.sh 创建验证记录时校验（需 Zone-DNS-Edit）"
      return 0
    fi
    zone=${zone#*.}
  done
  err "Token 有效，但无法访问 $domain 对应的 Zone；请检查域名托管、Token 资源范围和 Account ID"
  return 1
}

acme_resource_error() {
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
      *"can't fork"*|*"Cannot fork"*|*"cannot fork"*|*"fork: retry:"*|*"fork: Resource temporarily unavailable"*)
        err "acme.sh 无法创建子进程，证书操作未完成；请检查进程/线程数量、容器 PID 配额和内存，释放资源后重试"
        return 0 ;;
    esac
  done < "$1"
  return 1
}

acme_issue_error() {
  local log=$1
  if grep -Eqi 'Cannot init API|Can not init API|Unable to init API' "$log"; then
    err "ACME CA 初始化失败，请检查 CA 连接及 acme.sh 配置；这不表示 DNS Token 无效"
  elif grep -Eqi 'invalid domain|Error adding [Tt][Xx][Tt]|Add txt record error|Error add txt|authentication error|invalid access token|unauthorized|forbidden' "$log"; then
    err "证书申请被拒绝或 DNS 验证记录操作失败，请按上方日志检查授权、域名托管和 DNS 编辑权限"
  else
    err "证书申请失败，请根据上方 acme.sh 日志检查 CA、DNS 验证、网络或限流原因"
  fi
}

cert_dns() {
  local c dns name val plugin d="$CERT_DIR/$N_DOMAIN" rc log retry
  local -a pipe_rc
  install_acme || return 1
  acme_directory_check || return 1
  echo "DNS 服务商:  1) Cloudflare   2) 阿里云   3) DNSPod   4) 其他（acme.sh 插件）"
  c=$(ask "请选择" 1) || return 1
  case $c in
    1) dns=dns_cf
       info "Cloudflare 推荐使用 API Token（权限: Zone-DNS-Edit + Zone-Zone-Read）"
       while true; do
         export CF_Token; CF_Token=$(ask_secret "CF_Token") || return 1
         val=$(ask "CF_Account_ID（用户 Token 可留空，账户级 Token 必填）") || return 1
         export CF_Account_ID=$val
         cf_preflight && break
         read -rp "按回车重新填写 Cloudflare 凭据，输入 q 取消: " retry || return 1
         [[ $retry != [qQ] ]] || return 1
       done ;;
    2) dns=dns_ali
       export Ali_Key; Ali_Key=$(ask "Ali_Key (AccessKey ID)") || return 1
       export Ali_Secret; Ali_Secret=$(ask_secret "Ali_Secret") || return 1 ;;
    3) dns=dns_dp
       export DP_Id; DP_Id=$(ask "DP_Id") || return 1
       export DP_Key; DP_Key=$(ask_secret "DP_Key") || return 1 ;;
    4) plugin=$(ask "acme.sh DNS 插件名（如 dns_aws、dns_gd）") || return 1
       [[ $plugin =~ ^dns_[a-z0-9_]+$ && -f $ACME_HOME/dnsapi/$plugin.sh ]] || { err "插件 $plugin 不存在"; return 1; }
       dns=$plugin
       info "逐项输入该插件需要的环境变量，格式 NAME=value，直接回车结束"
       while true; do
         val=$(ask "环境变量") || return 1; [[ -z $val ]] && break
         name=${val%%=*}
         [[ $val == *=* && $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { warn "格式应为 NAME=value"; continue; }
         export "$name=${val#*=}"
       done ;;
    *) err "无效选择"; return 1 ;;
  esac
  info "正在申请证书（DNS 验证通常需要 1-2 分钟）..."
  log=$(mktemp) || return 1
  "$ACME_SH" --issue --server "$ACME_SERVER" --dns "$dns" -d "$N_DOMAIN" --keylength ec-256 2>&1 | tee "$log"
  pipe_rc=("${PIPESTATUS[@]}")
  rc=${pipe_rc[0]}
  if acme_resource_error "$log"; then
    rm -f "$log"; return 1
  fi
  if ((pipe_rc[1] != 0)); then
    err "无法记录证书申请日志，未继续安装证书"; rm -f "$log"; return 1
  fi
  if ((rc != 0 && rc != 2)); then
    acme_issue_error "$log"; rm -f "$log"; return 1
  fi
  mkdir -p "$d" || { rm -f "$log"; return 1; }
  "$ACME_SH" --install-cert -d "$N_DOMAIN" --ecc \
    --fullchain-file "$d/fullchain.pem" --key-file "$d/key.pem" --reloadcmd "$(reload_cmd)" > "$log" 2>&1
  rc=$?
  if acme_resource_error "$log"; then
    rm -f "$log"; return 1
  fi
  if ((rc != 0)); then
    cat "$log" >&2
    err "安装证书文件失败，无法确认签发和部署是否完成；请检查上方日志、acme.sh 配置和目录权限"
    rm -f "$log"; return 1
  fi
  rm -f "$log"
  [[ -s $d/fullchain.pem && -s $d/key.pem ]] || { err "证书安装失败"; return 1; }
  chmod 600 "$d/key.pem"
  N_CERTMODE=dns; N_CERT=$d/fullchain.pem; N_KEY=$d/key.pem; N_INSECURE=0
  info "证书已就绪，到期时间: $(cert_expiry "$N_CERT")，acme.sh 会自动续期"
}

cert_builtin() {
  local v p
  echo "sing-box 内置 ACME 验证方式:  1) HTTP-01（需要公网 80 端口）  2) TLS-ALPN-01（需要公网 443 端口）"
  v=$(ask "请选择" 1) || return 1
  if [[ $v == 2 ]]; then N_ACMEV=alpn; p=443; else N_ACMEV=http; p=80; fi
  if port_in_use "$p" tcp; then
    warn "本机 $p 端口已被占用，证书验证会失败"
    confirm "仍然继续?" n || return 1
  fi
  warn "NAT 机器没有公网 $p 端口时无法使用此方式，请改用 DNS-01"
  ask_acme_email || return 1
  N_CERTMODE=builtin; N_CERT=""; N_KEY=""; N_INSECURE=0
}

cert_manual() {
  local c k m1 m2
  while true; do
    c=$(ask "证书文件路径（fullchain/crt）") || return 1; k=$(ask "私钥文件路径（key）") || return 1
    if [[ ! -r $c || ! -r $k ]]; then warn "文件不存在或不可读"; continue; fi
    m1=$(openssl x509 -in "$c" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null)
    m2=$(openssl pkey -in "$k" -pubout 2>/dev/null | openssl md5 2>/dev/null)
    if [[ -z $m1 || $m1 != "$m2" ]]; then warn "证书与私钥不匹配或格式错误"; continue; fi
    break
  done
  if ! openssl x509 -in "$c" -noout -checkhost "$N_DOMAIN" 2>/dev/null | grep -q "does match"; then
    warn "证书中的域名与 $N_DOMAIN 不匹配"
    confirm "仍然使用?" n || return 1
  fi
  cert_valid "$c" || warn "该证书 30 天内到期或已过期"
  N_CERTMODE=manual; N_CERT=$c; N_KEY=$k; N_INSECURE=0
}

cert_self() {
  local d="$CERT_DIR/$N_DOMAIN"
  mkdir -p "$d"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$d/key.pem" -out "$d/fullchain.pem" -days 3650 \
    -subj "/CN=$N_DOMAIN" -addext "subjectAltName=DNS:$N_DOMAIN" >/dev/null 2>&1 \
    || { err "自签证书生成失败"; return 1; }
  chmod 600 "$d/key.pem"; touch "$d/.selfsigned"
  N_CERTMODE=self; N_CERT=$d/fullchain.pem; N_KEY=$d/key.pem; N_INSECURE=1
  info "已生成自签证书，客户端需要开启 insecure（跳过证书验证）"
}

# 选择证书方式并获取证书，结果写入 N_DOMAIN / N_CERT* 变量
cert_flow() {
  local m d
  echo "证书方式:"
  echo "  1) DNS-01 自动申请（acme.sh，NAT/没有 80、443 的机器推荐）"
  echo "  2) sing-box 内置 ACME（HTTP-01 / TLS-ALPN-01，需要公网 80 或 443）"
  echo "  3) 手动指定已有证书文件"
  echo "  4) 自签证书（无域名/测试用，客户端需 insecure）"
  ui_item 0 "返回"
  m=$(ask_choice "请选择" 4 1) || return 1
  [[ $m != 0 ]] || return 1
  if [[ $m == 4 ]]; then
    N_DOMAIN=$(ask_domain "证书域名/SNI（没有域名可填任意域名，如 www.bing.com）") || return 1
  else
    N_DOMAIN=$(ask_domain "域名（需已解析到本机或 NAT 出口）") || return 1
  fi
  d="$CERT_DIR/$N_DOMAIN"
  if [[ $m =~ ^[13]$ && -s $d/fullchain.pem && -s $d/key.pem && ! -e $d/.selfsigned ]] && cert_valid "$d/fullchain.pem"; then
    if confirm "发现 $N_DOMAIN 已有有效证书（到期: $(cert_expiry "$d/fullchain.pem")），直接复用?" y; then
      N_CERTMODE=dns; N_CERT=$d/fullchain.pem; N_KEY=$d/key.pem; N_INSECURE=0
      return 0
    fi
  fi
  case $m in
    1) cert_dns ;; 2) cert_builtin ;; 3) cert_manual ;; 4) cert_self ;;
    *) err "无效选择"; return 1 ;;
  esac
}
