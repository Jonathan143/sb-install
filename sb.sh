#!/usr/bin/env bash
#=====================================================================
# sb - sing-box 节点部署与管理脚本（交互式）
# 协议: VLESS+Reality / VLESS+WS+TLS / Hysteria2 / TUIC v5 / AnyTLS
#
# 安装: bash sb.sh                         （首次运行自动安装为 /usr/local/bin/sb）
#       SCRIPT_URL=<脚本直链> bash <(curl -fsSL <脚本直链>)
# 使用: sb            主菜单
#       sb help       查看全部子命令
#=====================================================================

SB_VERSION="1.0.3"
SCRIPT_URL="${SCRIPT_URL:-}"          # 脚本托管直链，用于 sb update 和管道安装
GH_PROXY="${GH_PROXY:-}"              # GitHub 下载加速前缀，例如 https://ghfast.top/

SB_DIR="${SB_DIR:-/etc/sing-box}"
CONF_DIR="$SB_DIR/conf.d"
META_DIR="$SB_DIR/meta"
CERT_DIR="$SB_DIR/certs"
BACKUP_DIR="$SB_DIR/backup"
SB_CONF="$SB_DIR/sb.conf"
SB_BIN="${SB_BIN:-/usr/local/bin/sing-box}"
SB_CMD="${SB_CMD:-/usr/local/bin/sb}"
SB_WORKDIR="/var/lib/sing-box"
SB_SERVICE="sing-box"
SB_LOCK="${SB_LOCK:-/tmp/sb.lock}"
ACME_HOME="${ACME_HOME:-/root/.acme.sh}"
ACME_SH="$ACME_HOME/acme.sh"
ACME_SERVER="https://acme-v02.api.letsencrypt.org/directory"

SNI_LIST=(
  www.microsoft.com www.apple.com addons.mozilla.org www.amazon.com
  www.nvidia.com www.samsung.com gateway.icloud.com dl.google.com
  www.asus.com www.intel.com www.amd.com www.cisco.com www.sony.com www.oracle.com
)

NODE_VARS=(N_ID N_PROTO N_LPORT N_PPORT N_HOST N_DOMAIN N_SNI N_UUID N_PASS N_FLOW
           N_PRIV N_PBK N_SID N_WSPATH N_CERTMODE N_CERT N_KEY N_INSECURE N_ACMEV
           N_OBFS N_NOTE N_CREATED)

#---------------------------------------------------------------------
# 基础工具
#---------------------------------------------------------------------
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; PLAIN=$'\033[0m'

info() { printf '%s[信息]%s %s\n' "$GREEN" "$PLAIN" "$*" >&2; }
warn() { printf '%s[警告]%s %s\n' "$YELLOW" "$PLAIN" "$*" >&2; }
err()  { printf '%s[错误]%s %s\n' "$RED" "$PLAIN" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ask "提示" [默认值]  -> 标准输出返回用户输入
ask() { local a; read -rp "$1${2:+ [$2]}: " a; echo "${a:-${2:-}}"; }
ask_secret() { local a; read -rsp "$1: " a; echo >&2; echo "$a"; }
# confirm "提示" [y|n]  -> 返回 0 表示确认
confirm() {
  local def=${2:-y} hint="[Y/n]" a
  [[ $def == n ]] && hint="[y/N]"
  read -rp "$1 $hint: " a
  a=${a:-$def}
  [[ $a =~ ^[Yy] ]]
}
pause() { local _; read -rp "按回车继续..." _; }

rand_str() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-16}"; echo; }
gen_uuid() { cat /proc/sys/kernel/random/uuid; }
urlenc() { jq -rn --arg s "$1" '$s|@uri'; }
version_ge() { [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1) == "$2" ]]; }
listen_addr() { [[ -e /proc/net/if_inet6 ]] && echo "::" || echo "0.0.0.0"; }

proto_label() {
  case ${1:-$N_PROTO} in
    reality) echo "VLESS+Reality" ;; ws) echo "VLESS+WS+TLS" ;; hy2) echo "Hysteria2" ;;
    tuic) echo "TUIC v5" ;; anytls) echo "AnyTLS" ;;
  esac
}
proto_net() { case ${1:-$N_PROTO} in hy2|tuic) echo udp ;; *) echo tcp ;; esac; }

#---------------------------------------------------------------------
# 全局配置 sb.conf
#---------------------------------------------------------------------
load_conf() {
  local env_url=$SCRIPT_URL
  SB_MODE=takeover; PORT_MIN=20000; PORT_MAX=60000; ACME_EMAIL=""
  [[ -f $SB_CONF ]] && . "$SB_CONF"
  [[ -n $env_url ]] && SCRIPT_URL=$env_url
  return 0
}
save_conf() {
  mkdir -p "$SB_DIR"
  printf 'SB_MODE=%q\nPORT_MIN=%q\nPORT_MAX=%q\nACME_EMAIL=%q\nSCRIPT_URL=%q\n' \
    "$SB_MODE" "$PORT_MIN" "$PORT_MAX" "$ACME_EMAIL" "$SCRIPT_URL" > "$SB_CONF"
  chmod 600 "$SB_CONF"
}

#---------------------------------------------------------------------
# 节点元数据
#---------------------------------------------------------------------
meta_reset() { local v; for v in "${NODE_VARS[@]}"; do printf -v "$v" '%s' ''; done; }
meta_load() { local f="$META_DIR/$1.env"; [[ $1 =~ ^[0-9]+$ && -f $f ]] || return 1; meta_reset; . "$f"; }
meta_save() {
  local v f="$META_DIR/$N_ID.env"
  { for v in "${NODE_VARS[@]}"; do printf '%s=%q\n' "$v" "${!v}"; done; } > "$f"
  chmod 600 "$f"
}
list_ids() { ls "$META_DIR" 2>/dev/null | sed -n 's/\.env$//p' | sort -n; }
next_id() { local i=1; while [[ -f $META_DIR/$i.env ]]; do i=$((i+1)); done; echo "$i"; }
conf_file() { printf '%s/%02d-%s.json' "$CONF_DIR" "$N_ID" "$N_PROTO"; }

#---------------------------------------------------------------------
# 系统 / 依赖
#---------------------------------------------------------------------
detect_pkg() {
  if command -v apt-get >/dev/null; then PKG=apt
  elif command -v dnf >/dev/null; then PKG=dnf
  elif command -v yum >/dev/null; then PKG=yum
  elif command -v apk >/dev/null; then PKG=apk
  else PKG=""; fi
}
pkg_install() {
  case $PKG in
    apt) apt-get update -y >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf|yum) "$PKG" install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
    *) err "未识别的包管理器，请手动安装: $*"; return 1 ;;
  esac
}
install_deps() {
  local need=() c
  detect_pkg
  for c in curl jq openssl tar; do command -v "$c" >/dev/null || need+=("$c"); done
  command -v ss >/dev/null || need+=("$([[ $PKG == dnf || $PKG == yum ]] && echo iproute || echo iproute2)")
  if ((${#need[@]})); then
    info "安装依赖: ${need[*]}"
    pkg_install ca-certificates "${need[@]}" >/dev/null 2>&1 || pkg_install "${need[@]}" || die "依赖安装失败"
  fi
  command -v qrencode >/dev/null || pkg_install qrencode >/dev/null 2>&1 || true
}

get_arch() {
  case $(uname -m) in
    x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;;
    armv7*) echo armv7 ;; i386|i686) echo 386 ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

has_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; }
svc() {
  local a=$1
  if has_systemd; then
    case $a in
      is-active) systemctl is-active --quiet "$SB_SERVICE" ;;
      *) systemctl "$a" "$SB_SERVICE" ;;
    esac
  else
    case $a in
      enable) rc-update add "$SB_SERVICE" default >/dev/null 2>&1 ;;
      disable) rc-update del "$SB_SERVICE" default >/dev/null 2>&1 ;;
      is-active) rc-service "$SB_SERVICE" status >/dev/null 2>&1 ;;
      *) rc-service "$SB_SERVICE" "$a" ;;
    esac
  fi
}

#---------------------------------------------------------------------
# sing-box 内核
#---------------------------------------------------------------------
core_version() {
  local output version
  [[ -x $SB_BIN ]] || return 1
  output=$("$SB_BIN" version 2>/dev/null) || return 1
  version=$(awk 'NR==1 && $1=="sing-box" && $2=="version" {print $3}' <<<"$output")
  [[ -n $version ]] || return 1
  printf '%s\n' "$version"
}

uses_musl() {
  [[ -f /etc/alpine-release ]] && return 0
  local output
  output=$(ldd --version 2>&1) # musl 的 ldd --version 可能返回非零
  [[ $output == *musl* ]]
}
latest_version() {
  curl -fsSL --max-time 15 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
    | jq -r '.tag_name // empty' | sed 's/^v//'
}
install_core() {
  local ver=${1:-} arch tmp url variant candidate output staged
  local variants=("" "-musl")
  arch=$(get_arch) || return 1
  uses_musl && variants=("-musl" "")
  [[ -z $ver ]] && ver=$(latest_version)
  [[ -z $ver ]] && ver=$(ask "无法获取最新版本，请手动输入版本号（如 1.12.0）")
  [[ -z $ver ]] && return 1
  ver=${ver#v}
  [[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+[-.a-zA-Z0-9]*$ ]] || { err "无效版本号: $ver"; return 1; }
  tmp=$(mktemp -d) || return 1
  for variant in "${variants[@]}"; do
    url="${GH_PROXY}https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}${variant}.tar.gz"
    info "下载 sing-box v$ver ($arch${variant}) ..."
    if ! curl -fL --retry 3 --connect-timeout 15 -o "$tmp/sb.tgz" "$url"; then
      warn "下载失败，尝试其他兼容构建"; continue
    fi
    rm -rf "$tmp/unpack"
    mkdir -p "$tmp/unpack" || { rm -rf "$tmp"; return 1; }
    if ! tar -xzf "$tmp/sb.tgz" -C "$tmp/unpack"; then
      warn "解压失败，尝试其他兼容构建"; continue
    fi
    candidate="$tmp/unpack/sing-box-${ver}-linux-${arch}${variant}/sing-box"
    # 先验证可执行性，再替换现有内核，避免安装失败破坏可用版本。
    if ! output=$(SB_BIN="$candidate" core_version); then
      warn "该构建无法运行，可能缺少动态加载器/运行库或架构不兼容"
      "$candidate" version >&2 2>&1
      continue
    fi
    mkdir -p "$(dirname "$SB_BIN")" || { rm -rf "$tmp"; return 1; }
    staged=$(mktemp "${SB_BIN}.new.XXXXXX") || { rm -rf "$tmp"; return 1; }
    if ! install -m 755 "$candidate" "$staged" ||
       ! SB_BIN="$staged" core_version >/dev/null ||
       ! mv -f "$staged" "$SB_BIN"; then
      err "内核安装失败，原内核未替换"
      rm -f "$staged"; rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    info "已安装: sing-box version $output"
    return 0
  done
  rm -rf "$tmp"
  err "没有成功安装可运行的内核，请检查下载网络（可设置 GH_PROXY）、系统运行库及 CPU 架构"
  return 1
}

sb_args() {
  SB_ARGS=(-D "$SB_WORKDIR")
  [[ $SB_MODE == coexist && -f $SB_DIR/config.json ]] && SB_ARGS+=(-c "$SB_DIR/config.json")
  SB_ARGS+=(-C "$CONF_DIR")
}

write_service() {
  sb_args
  mkdir -p "$SB_WORKDIR"
  if has_systemd; then
    cat > /etc/systemd/system/$SB_SERVICE.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target network-online.target

[Service]
ExecStart=$SB_BIN ${SB_ARGS[*]} run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  elif command -v rc-service >/dev/null; then
    cat > /etc/init.d/$SB_SERVICE <<EOF
#!/sbin/openrc-run
name="sing-box"
command="$SB_BIN"
command_args="${SB_ARGS[*]} run"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() { need net; }
EOF
    chmod +x /etc/init.d/$SB_SERVICE
  else
    warn "未检测到 systemd 或 OpenRC，需要自行管理 sing-box 进程"
  fi
}

write_base() {
  jq -n '{log:{level:"warn",timestamp:true},outbounds:[{type:"direct",tag:"direct"}]}' > "$CONF_DIR/00-base.json"
}

need_core() {
  core_version >/dev/null && return 0
  if [[ -e $SB_BIN ]]; then
    warn "sing-box 内核已存在但无法运行，需要重新安装兼容版本"
  else
    warn "尚未安装 sing-box 内核"
  fi
  confirm "现在安装最新版?" y || return 1
  install_core && write_service
}

#---------------------------------------------------------------------
# 初始化 / 自安装
#---------------------------------------------------------------------
self_install() {
  [[ $0 == "$SB_CMD" ]] && return 0
  mkdir -p "$(dirname "$SB_CMD")"
  if [[ -f $0 && -r $0 ]]; then
    install -m 755 "$0" "$SB_CMD.new" && mv -f "$SB_CMD.new" "$SB_CMD"
  elif [[ -n $SCRIPT_URL ]]; then
    curl -fsSL "$SCRIPT_URL" -o "$SB_CMD.new" && chmod +x "$SB_CMD.new" && mv -f "$SB_CMD.new" "$SB_CMD"
  else
    warn "无法自动安装 sb 命令（管道运行且未设置 SCRIPT_URL），请手动: cp 脚本 $SB_CMD && chmod +x $SB_CMD"
    return 1
  fi
  info "已安装快捷命令，之后直接输入 sb 即可"
}

ensure_init() {
  local c ts
  mkdir -p "$CONF_DIR" "$META_DIR" "$CERT_DIR" "$BACKUP_DIR" "$SB_WORKDIR"
  chmod 700 "$SB_DIR"
  if [[ ! -f $SB_CONF ]]; then
    if [[ -f $SB_DIR/config.json ]]; then
      echo
      warn "检测到已有配置 $SB_DIR/config.json（非本脚本生成）"
      echo "  1) 备份后由脚本接管（旧配置备份为 config.json.bak.时间，不再加载）"
      echo "  2) 保留旧配置，脚本只管理新增节点（两者合并加载）"
      c=$(ask "请选择" 1)
      if [[ $c == 2 ]]; then
        SB_MODE=coexist
      else
        ts=$(date +%Y%m%d-%H%M%S)
        mv "$SB_DIR/config.json" "$SB_DIR/config.json.bak.$ts"
        info "旧配置已备份到 config.json.bak.$ts"
        SB_MODE=takeover
      fi
    else
      SB_MODE=takeover
    fi
    save_conf
  fi
  [[ $SB_MODE == takeover && ! -f $CONF_DIR/00-base.json ]] && write_base
  return 0
}

bootstrap() {
  mkdir -p "$SB_DIR"
  load_conf
  install_deps
  self_install
  ensure_init
  save_conf
}

#---------------------------------------------------------------------
# 端口 / 防火墙
#---------------------------------------------------------------------
port_in_use() { # port tcp|udp
  local flag=-ltn; [[ $2 == udp ]] && flag=-lun
  ss -H $flag 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"
}
node_port_used() { # port [跳过的节点ID]
  local id
  for id in $(list_ids); do
    [[ $id == "${2:-}" ]] && continue
    grep -q "^N_LPORT=$1\$" "$META_DIR/$id.env" && return 0
  done
  return 1
}
rand_port() { # tcp|udp 跳过ID
  local i p
  for i in $(seq 1 300); do
    p=$((PORT_MIN + (RANDOM * 32768 + RANDOM) % (PORT_MAX - PORT_MIN + 1)))
    port_in_use "$p" "$1" || node_port_used "$p" "${2:-}" || { echo "$p"; return 0; }
  done
  return 1
}
# pick_port tcp|udp [跳过ID] [当前端口] -> PICKED
pick_port() {
  local net=$1 skip=${2:-} cur=${3:-} in p
  while true; do
    in=$(ask "监听端口（回车随机 ${PORT_MIN}-${PORT_MAX}；输入 起-止 可修改随机范围）")
    if [[ -z $in ]]; then
      p=$(rand_port "$net" "$skip") || { warn "范围内没有空闲端口，请修改范围"; continue; }
      info "已随机选择端口 $p"
    elif [[ $in =~ ^([0-9]+)-([0-9]+)$ ]]; then
      if ((BASH_REMATCH[1] >= 1 && BASH_REMATCH[1] < BASH_REMATCH[2] && BASH_REMATCH[2] <= 65535)); then
        PORT_MIN=${BASH_REMATCH[1]}; PORT_MAX=${BASH_REMATCH[2]}; save_conf
        info "随机范围已改为 ${PORT_MIN}-${PORT_MAX}，请重新输入或回车随机"
      else
        warn "范围无效"
      fi
      continue
    elif [[ $in =~ ^[0-9]+$ ]] && ((in >= 1 && in <= 65535)); then
      p=$in
    else
      warn "输入无效"; continue
    fi
    if [[ $p != "$cur" ]] && { port_in_use "$p" "$net" || node_port_used "$p" "$skip"; }; then
      warn "端口 $p 已被占用"; continue
    fi
    PICKED=$p; return 0
  done
}
ask_pub_port() { # 默认值
  local p
  while true; do
    p=$(ask "对外端口（NAT 机器填商家映射的外部端口，否则直接回车）" "$1")
    [[ $p =~ ^[0-9]+$ ]] && ((p >= 1 && p <= 65535)) && { echo "$p"; return; }
    warn "端口无效"
  done
}

fw_open() { # port tcp|udp
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$1/$2" >/dev/null && info "ufw 已放行 $1/$2"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$1/$2" >/dev/null && firewall-cmd --reload >/dev/null && info "firewalld 已放行 $1/$2"
  elif command -v iptables >/dev/null && iptables -S INPUT 2>/dev/null | grep -Eq -- '-P INPUT (DROP|REJECT)|-j (DROP|REJECT)'; then
    iptables -C INPUT -p "$2" --dport "$1" -j ACCEPT 2>/dev/null || iptables -I INPUT -p "$2" --dport "$1" -j ACCEPT
    info "iptables 已放行 $1/$2（如需持久化请自行保存规则）"
  fi
  return 0
}
fw_close() {
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow "$1/$2" >/dev/null 2>&1
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="$1/$2" >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1
  elif command -v iptables >/dev/null; then
    iptables -D INPUT -p "$2" --dport "$1" -j ACCEPT 2>/dev/null
  fi
  return 0
}

detect_ip() {
  local ip u
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ip.sb; do
    ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
  done
  ip=$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]')
  [[ $ip == *:* ]] && echo "$ip"
  return 0
}
host_fmt() { [[ $N_HOST == *:* ]] && echo "[$N_HOST]" || echo "$N_HOST"; }

#---------------------------------------------------------------------
# SNI（Reality）
#---------------------------------------------------------------------
check_sni() {
  local out
  out=$(echo | timeout 8 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -alpn h2 2>/dev/null)
  grep -q "TLSv1.3" <<<"$out" && grep -q "ALPN protocol: h2" <<<"$out"
}
pick_sni() { # -> PICKED
  local i in cand n=${#SNI_LIST[@]}
  echo "内置推荐 SNI（Reality 目标站，需支持 TLS1.3 + h2）:"
  for i in "${!SNI_LIST[@]}"; do printf '  %2d) %s\n' $((i + 1)) "${SNI_LIST[$i]}"; done
  in=$(ask "输入序号或直接输入域名（回车随机选一个）")
  if [[ -z $in ]]; then
    for i in 1 2 3 4 5; do
      cand=${SNI_LIST[RANDOM % n]}
      info "检测 $cand ..."
      check_sni "$cand" && { PICKED=$cand; info "已选择 $cand"; return 0; }
    done
    warn "多次检测未通过（可能是本机网络限制），直接使用 $cand"
    PICKED=$cand; return 0
  elif [[ $in =~ ^[0-9]+$ ]] && ((in >= 1 && in <= n)); then
    cand=${SNI_LIST[in - 1]}
  else
    cand=${in,,}
  fi
  info "检测 $cand 是否支持 TLS1.3 + h2 ..."
  if ! check_sni "$cand"; then
    warn "$cand 检测未通过，Reality 可能无法正常工作"
    confirm "仍然使用?" n || { pick_sni; return; }
  fi
  PICKED=$cand
}

#---------------------------------------------------------------------
# 证书
#---------------------------------------------------------------------
ask_domain() { # 提示
  local d
  while true; do
    d=$(ask "$1"); d=${d,,}
    [[ $d =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]] && { echo "$d"; return; }
    warn "域名格式不正确"
  done
}
cert_valid() { openssl x509 -checkend 2592000 -noout -in "$1" >/dev/null 2>&1; }
cert_expiry() { openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2; }
reload_cmd() { echo "systemctl restart $SB_SERVICE >/dev/null 2>&1 || rc-service $SB_SERVICE restart >/dev/null 2>&1 || true"; }

ask_acme_email() {
  if [[ -z $ACME_EMAIL ]]; then
    ACME_EMAIL=$(ask "ACME 账户邮箱（可留空）")
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
  ask_acme_email
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
  c=$(ask "请选择" 1)
  case $c in
    1) dns=dns_cf
       info "Cloudflare 推荐使用 API Token（权限: Zone-DNS-Edit + Zone-Zone-Read）"
       while true; do
         export CF_Token; CF_Token=$(ask_secret "CF_Token")
         val=$(ask "CF_Account_ID（用户 Token 可留空，账户级 Token 必填）")
         export CF_Account_ID=$val
         cf_preflight && break
         read -rp "按回车重新填写 Cloudflare 凭据，输入 q 取消: " retry || return 1
         [[ $retry != [qQ] ]] || return 1
       done ;;
    2) dns=dns_ali
       export Ali_Key; Ali_Key=$(ask "Ali_Key (AccessKey ID)")
       export Ali_Secret; Ali_Secret=$(ask_secret "Ali_Secret") ;;
    3) dns=dns_dp
       export DP_Id; DP_Id=$(ask "DP_Id")
       export DP_Key; DP_Key=$(ask_secret "DP_Key") ;;
    4) plugin=$(ask "acme.sh DNS 插件名（如 dns_aws、dns_gd）")
       [[ $plugin =~ ^dns_[a-z0-9_]+$ && -f $ACME_HOME/dnsapi/$plugin.sh ]] || { err "插件 $plugin 不存在"; return 1; }
       dns=$plugin
       info "逐项输入该插件需要的环境变量，格式 NAME=value，直接回车结束"
       while true; do
         val=$(ask "环境变量"); [[ -z $val ]] && break
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
  v=$(ask "请选择" 1)
  if [[ $v == 2 ]]; then N_ACMEV=alpn; p=443; else N_ACMEV=http; p=80; fi
  if port_in_use "$p" tcp; then
    warn "本机 $p 端口已被占用，证书验证会失败"
    confirm "仍然继续?" n || return 1
  fi
  warn "NAT 机器没有公网 $p 端口时无法使用此方式，请改用 DNS-01"
  ask_acme_email
  N_CERTMODE=builtin; N_CERT=""; N_KEY=""; N_INSECURE=0
}

cert_manual() {
  local c k m1 m2
  while true; do
    c=$(ask "证书文件路径（fullchain/crt）"); k=$(ask "私钥文件路径（key）")
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
  m=$(ask "请选择" 1)
  if [[ $m == 4 ]]; then
    N_DOMAIN=$(ask_domain "证书域名/SNI（没有域名可填任意域名，如 www.bing.com）")
  else
    N_DOMAIN=$(ask_domain "域名（需已解析到本机或 NAT 出口）")
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

#---------------------------------------------------------------------
# 生成服务端配置
#---------------------------------------------------------------------
tls_server_json() { # alpn(可空)
  if [[ $N_CERTMODE == builtin ]]; then
    jq -n --arg d "$N_DOMAIN" --arg email "$ACME_EMAIL" --arg v "$N_ACMEV" --arg alpn "$1" '
      {enabled:true,server_name:$d,
       acme:({domain:[$d],data_directory:"/var/lib/sing-box/acme",provider:"letsencrypt",
              disable_http_challenge:($v=="alpn"),disable_tls_alpn_challenge:($v=="http")}
             + (if $email!="" then {email:$email} else {} end))}
      + (if $alpn!="" then {alpn:[$alpn]} else {} end)'
  else
    jq -n --arg d "$N_DOMAIN" --arg c "$N_CERT" --arg k "$N_KEY" --arg alpn "$1" '
      {enabled:true,server_name:$d,certificate_path:$c,key_path:$k}
      + (if $alpn!="" then {alpn:[$alpn]} else {} end)'
  fi
}

write_node_conf() {
  local tag="${N_PROTO}-${N_ID}" listen tls f tmp
  listen=$(listen_addr); f=$(conf_file); tmp=$(mktemp)
  case $N_PROTO in
    reality)
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$N_LPORT" --arg uuid "$N_UUID" \
        --arg flow "$N_FLOW" --arg sni "$N_SNI" --arg priv "$N_PRIV" --arg sid "$N_SID" '
        {inbounds:[{type:"vless",tag:$tag,listen:$listen,listen_port:$port,
          users:[{uuid:$uuid} + (if $flow!="" then {flow:$flow} else {} end)],
          tls:{enabled:true,server_name:$sni,
               reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$priv,short_id:[$sid]}}}]}' > "$tmp" ;;
    ws)
      tls=$(tls_server_json "")
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$N_LPORT" --arg uuid "$N_UUID" \
        --arg path "$N_WSPATH" --argjson tls "$tls" '
        {inbounds:[{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{uuid:$uuid}],
          tls:$tls,transport:{type:"ws",path:$path}}]}' > "$tmp" ;;
    hy2)
      tls=$(tls_server_json "h3")
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$N_LPORT" --arg pw "$N_PASS" \
        --arg obfs "$N_OBFS" --argjson tls "$tls" '
        {inbounds:[{type:"hysteria2",tag:$tag,listen:$listen,listen_port:$port,users:[{password:$pw}],tls:$tls}
          + (if $obfs!="" then {obfs:{type:"salamander",password:$obfs}} else {} end)]}' > "$tmp" ;;
    tuic)
      tls=$(tls_server_json "h3")
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$N_LPORT" --arg uuid "$N_UUID" \
        --arg pw "$N_PASS" --argjson tls "$tls" '
        {inbounds:[{type:"tuic",tag:$tag,listen:$listen,listen_port:$port,users:[{uuid:$uuid,password:$pw}],
          congestion_control:"bbr",tls:$tls}]}' > "$tmp" ;;
    anytls)
      tls=$(tls_server_json "")
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$N_LPORT" --arg pw "$N_PASS" \
        --argjson tls "$tls" '
        {inbounds:[{type:"anytls",tag:$tag,listen:$listen,listen_port:$port,users:[{password:$pw}],tls:$tls}]}' > "$tmp" ;;
    *) rm -f "$tmp"; return 1 ;;
  esac
  mv -f "$tmp" "$f"; chmod 600 "$f"
}

#---------------------------------------------------------------------
# 分享链接 / 客户端配置
#---------------------------------------------------------------------
node_link() {
  local host name q
  host=$(host_fmt); name=$(urlenc "${N_NOTE:-$N_PROTO-$N_ID}")
  case $N_PROTO in
    reality)
      q="encryption=none&security=reality&sni=$N_SNI&fp=chrome&pbk=$N_PBK&sid=$N_SID&type=tcp"
      [[ -n $N_FLOW ]] && q="$q&flow=$N_FLOW"
      echo "vless://$N_UUID@$host:$N_PPORT?$q#$name" ;;
    ws)
      q="encryption=none&security=tls&sni=$N_DOMAIN&fp=chrome&type=ws&host=$N_DOMAIN&path=$(urlenc "$N_WSPATH")"
      [[ $N_INSECURE == 1 ]] && q="$q&allowInsecure=1"
      echo "vless://$N_UUID@$host:$N_PPORT?$q#$name" ;;
    hy2)
      q="sni=$N_DOMAIN"
      [[ -n $N_OBFS ]] && q="$q&obfs=salamander&obfs-password=$N_OBFS"
      [[ $N_INSECURE == 1 ]] && q="$q&insecure=1"
      echo "hysteria2://$N_PASS@$host:$N_PPORT?$q#$name" ;;
    tuic)
      q="congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$N_DOMAIN"
      [[ $N_INSECURE == 1 ]] && q="$q&allow_insecure=1"
      echo "tuic://$N_UUID:$N_PASS@$host:$N_PPORT?$q#$name" ;;
    anytls)
      q="sni=$N_DOMAIN"
      [[ $N_INSECURE == 1 ]] && q="$q&insecure=1"
      echo "anytls://$N_PASS@$host:$N_PPORT?$q#$name" ;;
  esac
}

node_outbound() {
  local tag="${N_NOTE:-$N_PROTO-$N_ID}" ins=false
  [[ $N_INSECURE == 1 ]] && ins=true
  case $N_PROTO in
    reality)
      jq -n --arg tag "$tag" --arg server "$N_HOST" --argjson port "$N_PPORT" --arg uuid "$N_UUID" \
        --arg flow "$N_FLOW" --arg sni "$N_SNI" --arg pbk "$N_PBK" --arg sid "$N_SID" '
        {type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid,
         tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},
              reality:{enabled:true,public_key:$pbk,short_id:$sid}}}
        | if $flow!="" then .flow=$flow else . end' ;;
    ws)
      jq -n --arg tag "$tag" --arg server "$N_HOST" --argjson port "$N_PPORT" --arg uuid "$N_UUID" \
        --arg d "$N_DOMAIN" --arg path "$N_WSPATH" --argjson ins "$ins" '
        {type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid,
         tls:{enabled:true,server_name:$d,insecure:$ins,utls:{enabled:true,fingerprint:"chrome"}},
         transport:{type:"ws",path:$path,headers:{Host:$d}}}' ;;
    hy2)
      jq -n --arg tag "$tag" --arg server "$N_HOST" --argjson port "$N_PPORT" --arg pw "$N_PASS" \
        --arg d "$N_DOMAIN" --arg obfs "$N_OBFS" --argjson ins "$ins" '
        {type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$pw,
         tls:{enabled:true,server_name:$d,insecure:$ins,alpn:["h3"]}}
        | if $obfs!="" then .obfs={type:"salamander",password:$obfs} else . end' ;;
    tuic)
      jq -n --arg tag "$tag" --arg server "$N_HOST" --argjson port "$N_PPORT" --arg uuid "$N_UUID" \
        --arg pw "$N_PASS" --arg d "$N_DOMAIN" --argjson ins "$ins" '
        {type:"tuic",tag:$tag,server:$server,server_port:$port,uuid:$uuid,password:$pw,
         congestion_control:"bbr",udp_relay_mode:"native",
         tls:{enabled:true,server_name:$d,insecure:$ins,alpn:["h3"]}}' ;;
    anytls)
      jq -n --arg tag "$tag" --arg server "$N_HOST" --argjson port "$N_PPORT" --arg pw "$N_PASS" \
        --arg d "$N_DOMAIN" --argjson ins "$ins" '
        {type:"anytls",tag:$tag,server:$server,server_port:$port,password:$pw,
         tls:{enabled:true,server_name:$d,insecure:$ins}}' ;;
  esac
}

show_node() {
  local link
  meta_load "$1" || { err "节点 $1 不存在"; return 1; }
  echo "=================================================="
  echo "编号: $N_ID    协议: $(proto_label)    备注: $N_NOTE"
  echo "地址: $N_HOST    对外端口: $N_PPORT    监听端口: $N_LPORT"
  [[ -n $N_DOMAIN ]] && echo "域名/SNI: $N_DOMAIN"
  [[ $N_PROTO == reality ]] && echo "SNI: $N_SNI    Flow: ${N_FLOW:-关闭}"
  [[ $N_INSECURE == 1 ]] && echo "${YELLOW}自签证书：客户端需开启 insecure${PLAIN}"
  echo "--------------------------------------------------"
  link=$(node_link)
  echo "分享链接:"; echo "$link"
  command -v qrencode >/dev/null && { echo; qrencode -t ANSIUTF8 "$link"; }
  echo "--------------------------------------------------"
  echo "sing-box 客户端 outbound:"; node_outbound
  echo "=================================================="
}

write_nodes_txt() {
  local id
  { for id in $(list_ids); do meta_load "$id" && { echo "# [$id] $(proto_label) $N_NOTE"; node_link; echo; }; done; } > "$SB_DIR/nodes.txt"
  chmod 600 "$SB_DIR/nodes.txt"
}

#---------------------------------------------------------------------
# 快照 / 应用 / 回滚
#---------------------------------------------------------------------
snapshot() {
  LAST_SNAP="$BACKUP_DIR/snap-$(date +%Y%m%d-%H%M%S).tgz"
  tar -czf "$LAST_SNAP" -C "$SB_DIR" conf.d meta 2>/dev/null
  ls -1t "$BACKUP_DIR"/snap-*.tgz 2>/dev/null | tail -n +11 | xargs -r rm -f
}
restore_snapshot() {
  [[ -f $LAST_SNAP ]] || return 1
  rm -rf "$CONF_DIR" "$META_DIR"
  tar -xzf "$LAST_SNAP" -C "$SB_DIR"
  warn "已回滚到变更前的配置"
}
# 校验配置并重启，失败自动回滚
apply_config() {
  local log=/tmp/sb-check.log
  sb_args
  if ! "$SB_BIN" "${SB_ARGS[@]}" check >"$log" 2>&1; then
    err "配置校验失败:"; cat "$log" >&2
    restore_snapshot; return 1
  fi
  write_service
  svc enable >/dev/null 2>&1
  svc restart >/dev/null 2>&1
  sleep 2
  if ! svc is-active; then
    err "sing-box 启动失败，最近日志:"
    has_systemd && journalctl -u "$SB_SERVICE" -n 15 --no-pager >&2 || tail -n 15 /var/log/sing-box.log >&2 2>/dev/null
    restore_snapshot; write_service; svc restart >/dev/null 2>&1
    return 1
  fi
  write_nodes_txt
  return 0
}

#---------------------------------------------------------------------
# 节点操作
#---------------------------------------------------------------------
select_node() { # [id] -> SEL_ID
  local id=${1:-}
  if [[ -z $id ]]; then
    [[ -n $(list_ids) ]] || { info "暂无节点"; return 1; }
    list_nodes
    id=$(ask "请输入节点编号")
  fi
  [[ $id =~ ^[0-9]+$ && -f $META_DIR/$id.env ]] || { err "节点 $id 不存在"; return 1; }
  SEL_ID=$id
}

list_nodes() {
  local id st
  [[ -n $(list_ids) ]] || { echo "暂无节点"; return 0; }
  printf '%-5s %-15s %-8s %-8s %-26s %-8s %s\n' 编号 协议 监听 对外 地址 状态 备注
  for id in $(list_ids); do
    meta_load "$id" || continue
    if port_in_use "$N_LPORT" "$(proto_net)"; then st="${GREEN}运行${PLAIN}"; else st="${RED}未监听${PLAIN}"; fi
    printf '%-5s %-15s %-8s %-8s %-26s %b   %s\n' "$N_ID" "$(proto_label)" "$N_LPORT" "$N_PPORT" "$N_HOST" "$st" "$N_NOTE"
  done
}

add_node() {
  local p def_host cdn
  need_core || return 1
  echo "选择协议:"
  echo "  1) VLESS + Reality"
  echo "  2) VLESS + WS + TLS"
  echo "  3) Hysteria2"
  echo "  4) TUIC v5"
  echo "  5) AnyTLS"
  p=$(ask "请选择" 1)
  meta_reset
  N_ID=$(next_id); N_CREATED=$(date '+%F %T')
  case $p in
    1) N_PROTO=reality ;; 2) N_PROTO=ws ;; 3) N_PROTO=hy2 ;; 4) N_PROTO=tuic ;; 5) N_PROTO=anytls ;;
    *) err "无效选择"; return 1 ;;
  esac
  if [[ $N_PROTO == anytls ]] && ! version_ge "$(core_version)" 1.12.0; then
    warn "AnyTLS 需要 sing-box 1.12.0 及以上，当前为 $(core_version)"
    confirm "现在更新内核?" y && install_core || return 1
  fi

  pick_port "$(proto_net)" "" ""; N_LPORT=$PICKED
  N_PPORT=$(ask_pub_port "$N_LPORT")

  case $N_PROTO in
    reality)
      N_UUID=$(gen_uuid); N_SID=$(openssl rand -hex 8)
      local keys; keys=$("$SB_BIN" generate reality-keypair) || { err "生成密钥失败"; return 1; }
      N_PRIV=$(awk '/PrivateKey/{print $2}' <<<"$keys"); N_PBK=$(awk '/PublicKey/{print $2}' <<<"$keys")
      if confirm "启用 Flow (xtls-rprx-vision)？（不能与 multiplex 同时使用，客户端需支持）" y; then
        N_FLOW=xtls-rprx-vision
      fi
      pick_sni; N_SNI=$PICKED
      def_host=$(detect_ip) ;;
    ws|hy2|tuic|anytls)
      case $N_PROTO in
        ws) N_UUID=$(gen_uuid); N_WSPATH="/$(rand_str 8)" ;;
        hy2) N_PASS=$(rand_str 16)
             confirm "启用 salamander 混淆？" n && N_OBFS=$(rand_str 16) ;;
        tuic) N_UUID=$(gen_uuid); N_PASS=$(rand_str 16) ;;
        anytls) N_PASS=$(rand_str 16) ;;
      esac
      cert_flow || { err "证书配置失败，已取消"; return 1; }
      if [[ $N_CERTMODE == self ]]; then def_host=$(detect_ip); else def_host=$N_DOMAIN; fi
      if [[ $N_PROTO == ws ]]; then
        cdn=" 443 2053 2083 2087 2096 8443 "
        [[ $cdn != *" $N_PPORT "* ]] && info "提示: 若要经 Cloudflare CDN，对外端口需为 443/2053/2083/2087/2096/8443"
      fi ;;
  esac
  [[ $(proto_net) == udp ]] && info "提示: $(proto_label) 使用 UDP，NAT 机器请确认商家已映射 UDP 端口"

  N_HOST=$(ask "客户端连接地址（IP 或域名）" "$def_host")
  [[ -z $N_HOST ]] && { err "地址不能为空"; return 1; }
  N_NOTE=$(ask "节点备注" "$(proto_label)-$N_ID")

  snapshot
  meta_save
  write_node_conf || { err "生成配置失败"; restore_snapshot; return 1; }
  fw_open "$N_LPORT" "$(proto_net)"
  if apply_config; then
    info "节点已添加并生效"
    show_node "$N_ID"
  else
    meta_load "$N_ID" 2>/dev/null || true
    fw_close "$N_LPORT" "$(proto_net)"
    return 1
  fi
}

edit_node() {
  local old_l old_net c v keys
  select_node "${1:-}" || return 1
  meta_load "$SEL_ID"
  old_l=$N_LPORT; old_net=$(proto_net)
  echo "修改节点 [$N_ID] $(proto_label) $N_NOTE"
  echo "  1) 端口（监听 / 对外）"
  echo "  2) $([[ $N_PROTO == reality ]] && echo 'SNI' || echo '域名与证书')"
  echo "  3) Reality Flow 开关"
  echo "  4) 重新生成 UUID / 密码 / 密钥"
  echo "  5) 客户端连接地址"
  echo "  6) 备注"
  echo "  7) Hysteria2 混淆开关"
  c=$(ask "请选择")
  snapshot
  case $c in
    1) pick_port "$(proto_net)" "$N_ID" "$old_l"; N_LPORT=$PICKED
       N_PPORT=$(ask_pub_port "$N_PPORT") ;;
    2) if [[ $N_PROTO == reality ]]; then pick_sni; N_SNI=$PICKED
       else cert_flow || return 1; fi ;;
    3) [[ $N_PROTO == reality ]] || { warn "仅 Reality 支持"; return 1; }
       if [[ -n $N_FLOW ]]; then N_FLOW=""; info "Flow 已关闭"; else N_FLOW=xtls-rprx-vision; info "Flow 已开启"; fi ;;
    4) case $N_PROTO in
         reality) N_UUID=$(gen_uuid); N_SID=$(openssl rand -hex 8)
                  keys=$("$SB_BIN" generate reality-keypair) || return 1
                  N_PRIV=$(awk '/PrivateKey/{print $2}' <<<"$keys"); N_PBK=$(awk '/PublicKey/{print $2}' <<<"$keys") ;;
         ws) N_UUID=$(gen_uuid) ;;
         tuic) N_UUID=$(gen_uuid); N_PASS=$(rand_str 16) ;;
         hy2|anytls) N_PASS=$(rand_str 16); [[ -n $N_OBFS ]] && N_OBFS=$(rand_str 16) ;;
       esac ;;
    5) N_HOST=$(ask "客户端连接地址" "$N_HOST") ;;
    6) N_NOTE=$(ask "备注" "$N_NOTE") ;;
    7) [[ $N_PROTO == hy2 ]] || { warn "仅 Hysteria2 支持"; return 1; }
       if [[ -n $N_OBFS ]]; then N_OBFS=""; info "混淆已关闭"; else N_OBFS=$(rand_str 16); info "混淆已开启"; fi ;;
    *) err "无效选择"; return 1 ;;
  esac
  meta_save
  write_node_conf || { restore_snapshot; return 1; }
  if [[ $N_LPORT != "$old_l" ]]; then fw_close "$old_l" "$old_net"; fw_open "$N_LPORT" "$old_net"; fi
  if apply_config; then info "修改已生效"; show_node "$SEL_ID"; else err "修改失败，已回滚"; return 1; fi
}

delete_node() {
  local id other
  select_node "${1:-}" || return 1
  id=$SEL_ID
  meta_load "$id"
  confirm "确认删除节点 [$id] $(proto_label) $N_NOTE ?" n || return 0
  snapshot
  local dom=$N_DOMAIN mode=$N_CERTMODE net; net=$(proto_net)
  fw_close "$N_LPORT" "$net"
  rm -f "$(conf_file)" "$META_DIR/$id.env"
  if [[ -z $(list_ids) ]]; then
    svc stop >/dev/null 2>&1; write_nodes_txt
    info "已无任何节点，sing-box 服务已停止"
  else
    apply_config || return 1
  fi
  info "节点 $id 已删除"
  # 证书清理：该域名不再被其它节点使用时询问
  if [[ -n $dom && $mode != builtin && $mode != manual ]]; then
    other=0
    for i in $(list_ids); do meta_load "$i" && [[ $N_DOMAIN == "$dom" ]] && other=1; done
    if ((other == 0)) && [[ -d $CERT_DIR/$dom ]]; then
      if confirm "域名 $dom 的证书已无节点使用，是否删除证书文件? （保留可避免再次申请触发频率限制）" n; then
        [[ $mode == dns && -x $ACME_SH ]] && "$ACME_SH" --remove -d "$dom" --ecc >/dev/null 2>&1
        rm -rf "${CERT_DIR:?}/$dom"; info "证书已删除"
      fi
    fi
  fi
}

#---------------------------------------------------------------------
# 状态 / 日志 / 服务
#---------------------------------------------------------------------
show_status() {
  local pid id
  echo "内核: $(core_version || true)    脚本: v$SB_VERSION    配置模式: $SB_MODE"
  if svc is-active; then echo -e "服务状态: ${GREEN}运行中${PLAIN}"; else echo -e "服务状态: ${RED}未运行${PLAIN}"; fi
  if has_systemd; then
    echo "开机自启: $(systemctl is-enabled "$SB_SERVICE" 2>/dev/null)"
    pid=$(systemctl show -p MainPID --value "$SB_SERVICE" 2>/dev/null)
    if [[ -n $pid && $pid != 0 ]]; then
      echo "PID: $pid    内存: $(ps -o rss= -p "$pid" | awk '{printf "%.1f MB", $1/1024}')    启动于: $(systemctl show -p ActiveEnterTimestamp --value "$SB_SERVICE")"
    fi
  fi
  echo; list_nodes; echo
  for id in $(list_ids); do
    meta_load "$id" || continue
    if [[ $N_CERTMODE == builtin ]]; then
      echo "[$id] $N_DOMAIN 证书: sing-box 内置 ACME 自动管理"
    elif [[ -n $N_CERT && -r $N_CERT ]]; then
      echo "[$id] $N_DOMAIN 证书到期: $(cert_expiry "$N_CERT")"
    fi
  done
}

show_log() {
  if has_systemd; then
    if [[ ${1:-} == -f ]]; then journalctl -u "$SB_SERVICE" -f; else journalctl -u "$SB_SERVICE" -n 80 --no-pager; fi
  else
    if [[ ${1:-} == -f ]]; then tail -f /var/log/sing-box.log; else tail -n 80 /var/log/sing-box.log; fi
  fi
}

svc_cmd() { # start|stop|restart
  if [[ $1 != stop ]]; then
    sb_args
    "$SB_BIN" "${SB_ARGS[@]}" check || { err "配置校验未通过，已取消"; return 1; }
  fi
  svc "$1" && info "已执行: $1"
  sleep 1
  svc is-active && info "当前状态: 运行中" || info "当前状态: 未运行"
}

service_menu() {
  echo "  1) 启动   2) 停止   3) 重启   4) 开机自启开   5) 开机自启关"
  case $(ask "请选择") in
    1) svc_cmd start ;; 2) svc_cmd stop ;; 3) svc_cmd restart ;;
    4) svc enable && info "已开启开机自启" ;; 5) svc disable && info "已关闭开机自启" ;;
  esac
}

#---------------------------------------------------------------------
# 证书管理 / 内核与脚本更新 / 卸载
#---------------------------------------------------------------------
cert_menu() {
  local d dom c rc=0
  echo "已保存的证书:"
  for d in "$CERT_DIR"/*/; do
    [[ -s ${d}fullchain.pem ]] || continue
    dom=$(basename "$d")
    printf '  %-32s 到期: %s%s\n' "$dom" "$(cert_expiry "${d}fullchain.pem")" "$([[ -e ${d}.selfsigned ]] && echo '  (自签)')"
  done
  echo
  echo "  1) 强制续期某个域名（acme.sh）   0) 返回"
  c=$(ask "请选择" 0)
  [[ $c != 0 ]] || return 0
  if [[ $c == 1 ]]; then
    if [[ -x $ACME_SH ]]; then
      dom=$(ask_domain "域名")
      "$ACME_SH" --renew -d "$dom" --ecc --force && info "续期完成（证书已自动部署并重启服务）"
      rc=$?
    else
      err "尚未安装 acme.sh"; rc=1
    fi
  else
    warn "无效选择"; rc=1
  fi
  [[ ${1:-} != pause ]] || pause
  return "$rc"
}

update_core() {
  local cur new
  cur=$(core_version); new=$(latest_version)
  echo "当前内核: ${cur:-未安装}    最新版本: ${new:-未知}"
  confirm "安装/更新到 ${new:-最新版}?" y || return 0
  [[ -x $SB_BIN ]] && cp -f "$SB_BIN" "$SB_BIN.bak"
  install_core "$new" || { [[ -f $SB_BIN.bak ]] && mv -f "$SB_BIN.bak" "$SB_BIN"; return 1; }
  sb_args
  if "$SB_BIN" "${SB_ARGS[@]}" check >/dev/null 2>&1; then
    write_service; svc restart >/dev/null 2>&1; info "内核已更新并重启"; rm -f "$SB_BIN.bak"
  else
    err "新内核与现有配置不兼容，已回退"; mv -f "$SB_BIN.bak" "$SB_BIN"
  fi
}

core_menu() {
  echo "  1) 安装/更新到最新版   2) 安装指定版本   3) 查看当前版本"
  case $(ask "请选择") in
    1) update_core ;;
    2) install_core "$(ask "版本号（如 1.12.0）")" && write_service ;;
    3) echo "$(core_version || echo 未安装)" ;;
  esac
}

restart_script() {
  local reply
  read -rp "按回车重新运行 sb..." reply || exit 0
  # Release the old process's lock before the new script acquires its own.
  exec 9>&-
  exec bash "$SB_CMD"
  err "重新运行失败，请手动运行 sb"
  exit 1
}

update_script() {
  local tmp new
  [[ -n $SCRIPT_URL ]] || { err "未设置 SCRIPT_URL，无法在线更新。可用 SCRIPT_URL=<直链> sb update 指定一次"; return 1; }
  tmp=$(mktemp)
  curl -fsSL "$SCRIPT_URL" -o "$tmp" || { err "下载失败"; rm -f "$tmp"; return 1; }
  bash -n "$tmp" || { err "下载的脚本语法有误，已取消"; rm -f "$tmp"; return 1; }
  new=$(sed -n 's/^SB_VERSION="\(.*\)"/\1/p' "$tmp" | head -n1)
  info "当前 v$SB_VERSION，远程 v${new:-?}"
  confirm "更新脚本?" y || { rm -f "$tmp"; return 0; }
  if ! install -m 755 "$tmp" "$SB_CMD.new" || ! mv -f "$SB_CMD.new" "$SB_CMD"; then
    rm -f "$tmp" "$SB_CMD.new"
    err "脚本安装失败，未重新运行"
    return 1
  fi
  rm -f "$tmp"
  save_conf
  if [[ ${1:-} == restart ]]; then
    info "脚本已更新"
    restart_script
  fi
  info "脚本已更新，请重新运行 sb"
}

uninstall_all() {
  local id
  confirm "确认卸载 sing-box 及 sb 命令?" n || return 0
  for id in $(list_ids); do meta_load "$id" && fw_close "$N_LPORT" "$(proto_net)"; done
  svc stop >/dev/null 2>&1; svc disable >/dev/null 2>&1
  rm -f /etc/systemd/system/$SB_SERVICE.service /etc/init.d/$SB_SERVICE "$SB_BIN" "$SB_BIN.bak"
  has_systemd && systemctl daemon-reload
  if ! confirm "保留配置与证书目录 $SB_DIR ?" y; then
    rm -rf "$SB_DIR" "$SB_WORKDIR"
    if [[ -x $ACME_SH ]] && confirm "同时卸载 acme.sh?" n; then "$ACME_SH" --uninstall >/dev/null 2>&1; rm -rf "$ACME_HOME"; fi
  fi
  rm -f "$SB_CMD"
  info "卸载完成"
}

#---------------------------------------------------------------------
# 主菜单 / 入口
#---------------------------------------------------------------------
usage() {
  cat <<EOF
sb v$SB_VERSION - sing-box 节点管理
用法: sb [命令]
  (无)            打开交互菜单
  add             新增节点
  list            列出节点
  info [编号]     查看节点链接/二维码/客户端配置
  edit [编号]     修改节点
  del [编号]      删除节点
  status          运行状态、证书到期时间
  log [-f]        查看日志（-f 实时）
  start|stop|restart   服务控制
  cert            证书管理
  core            安装/更新 sing-box 内核
  update          更新 sb 脚本
  uninstall       卸载
EOF
}

main_menu() {
  local c st installed
  while true; do
    installed=$(sed -n 's/^SB_VERSION="\([0-9][0-9.]*\)"/\1/p' "$SB_CMD" 2>/dev/null | head -n1)
    if [[ -n $installed && $installed != "$SB_VERSION" ]]; then
      info "当前运行 v${SB_VERSION}，磁盘已安装 v${installed}，需要重新加载脚本"
      restart_script
    fi
    if svc is-active; then st="${GREEN}运行中${PLAIN}"; else st="${RED}未运行${PLAIN}"; fi
    echo
    echo -e "${CYAN}========== sing-box 管理脚本 v$SB_VERSION ==========${PLAIN}"
    echo -e "状态: $st   内核: $(core_version || echo 未安装)   节点: $(list_ids | grep -c .)"
    echo "  1) 新增节点        6) 查看日志"
    echo "  2) 查看节点        7) 服务控制"
    echo "  3) 修改节点        8) 证书管理"
    echo "  4) 删除节点        9) 更新内核 / 脚本"
    echo "  5) 运行状态       10) 卸载"
    echo "  0) 退出"
    c=$(ask "请选择")
    case $c in
      1) add_node ;;
      2) if select_node ""; then show_node "$SEL_ID"; fi ;;
      3) edit_node ;;
      4) delete_node ;;
      5) show_status ;;
      6) show_log ;;
      7) service_menu ;;
      8) cert_menu pause; continue ;;
      9) echo "  1) 更新内核   2) 更新脚本"; case $(ask "请选择") in 1) update_core ;; 2) update_script restart ;; esac ;;
      10) uninstall_all; [[ -x $SB_CMD ]] || return ;;
      0|q) return ;;
      *) warn "无效选择" ;;
    esac
    pause
  done
}


# fdinfo identifies the open file description holding the lock, including locks
# inherited by children. Merely opening the same file does not make a holder.
lock_pid_holds() {
  local pid=$1
  [[ $pid =~ ^[0-9]+$ && $pid != $$ && $pid != "$BASHPID" ]] || return 1
  [[ /proc/$pid/fd/9 -ef $SB_LOCK ]] || return 1
  grep -Eq '^lock:.* FLOCK +ADVISORY +WRITE ' "/proc/$pid/fdinfo/9" 2>/dev/null
}
lock_holders() {
  local entry pid
  for entry in /proc/[0-9]*/fd/9; do
    pid=${entry#/proc/}; pid=${pid%%/*}
    lock_pid_holds "$pid" && printf '%s\n' "$pid"
  done
  return 0
}
lock_start_time() {
  local stat
  IFS= read -r stat < "/proc/$1/stat" || return 1
  # comm may contain spaces and parentheses; starttime is field 22.
  stat=${stat##*) }
  awk '{print $20}' <<< "$stat"
}
lock_is_manager() {
  local pid=$1 exe arg first=yes script=""
  exe=$(readlink "/proc/$pid/exe") || return 1
  [[ ${exe##*/} == bash ]] || return 1
  while IFS= read -r -d '' arg; do
    if [[ $first == yes ]]; then first=no; continue; fi
    case $arg in
      -c|-*c*) return 1 ;;
      -*) continue ;;
      *) script=$arg; break ;;
    esac
  done < "/proc/$pid/cmdline"
  [[ -n $script ]] || return 1
  [[ $script == /* ]] || script="/proc/$pid/cwd/$script"
  [[ $script == "$SB_CMD" || $script -ef $SB_CMD || $script -ef ${BASH_SOURCE[0]} ]]
}
lock_show_process() {
  local pid=$1 arg
  printf 'PID: %s\n' "$pid" >&2
  # BusyBox ps may not support these columns; /proc still supplies the command.
  ps -p "$pid" -o pid,ppid,user,etime,args >&2 2>/dev/null && return 0
  printf '命令: ' >&2
  while IFS= read -r -d '' arg; do printf '%q ' "$arg" >&2; done < "/proc/$pid/cmdline"
  printf '\n' >&2
}
lock_interactive() { [[ -t 0 ]]; }
acquire_lock() {
  command -v flock >/dev/null || return 0
  exec 9>>"$SB_LOCK" || { err "无法打开锁文件: $SB_LOCK"; return 1; }
  flock -n 9 && return 0
  local pid start current
  local managers=() starts=()
  warn "已有另一个 sb 实例正在运行，占用进程信息:"
  while IFS= read -r pid; do
    lock_show_process "$pid"
    start=$(lock_start_time "$pid" 2>/dev/null) || continue
    if [[ -n $start ]] && lock_is_manager "$pid" 2>/dev/null; then
      managers+=("$pid"); starts+=("$start")
    fi
  done < <(lock_holders)
  # The previous process may have exited while we were inspecting it.
  flock -n 9 && return 0
  if ((${#managers[@]} != 1)); then
    err "无法唯一确认持锁的 sb 管理进程，请根据进程信息手动处理后重试"
    return 1
  fi
  pid=${managers[0]}; start=${starts[0]}
  lock_interactive || { err "非交互运行不会终止其他实例，请在终端运行 sb 处理"; return 1; }
  warn "终止管理进程可能中断其正在执行的操作"
  confirm "是否终止 sb 进程 $pid 并继续?" n || return 1
  flock -n 9 && return 0
  current=$(lock_start_time "$pid" 2>/dev/null) || current=""
  if [[ $current != "$start" ]] || ! lock_pid_holds "$pid" || ! lock_is_manager "$pid"; then
    err "占用进程已变化，未发送终止信号，请重试"
    return 1
  fi
  if ! kill -TERM "$pid"; then
    flock -n 9 && return 0
    err "无法终止进程 $pid，请检查权限后重试"
    return 1
  fi
  if flock -w 5 9; then
    info "已取得运行锁，继续启动"
    return 0
  fi
  err "终止请求已发送，但锁尚未释放（进程可能正在执行命令，或子进程继承了锁）"
  while IFS= read -r pid; do lock_show_process "$pid"; done < <(lock_holders)
  err "请等待操作结束或手动处理上述进程后重试；不要删除锁文件"
  return 1
}

main() {
  case ${1:-} in
    -h|--help|help) usage; return 0 ;;
    -v|--version|version) echo "sb v$SB_VERSION"; return 0 ;;
  esac
  [[ $EUID -eq 0 ]] || die "请使用 root 用户运行"
  acquire_lock || return 1
  bootstrap
  case ${1:-} in
    "") need_core && write_service; main_menu ;;
    add) add_node ;;
    list|ls) list_nodes ;;
    info) select_node "${2:-}" && show_node "$SEL_ID" ;;
    edit) edit_node "${2:-}" ;;
    del|delete|rm) delete_node "${2:-}" ;;
    status) show_status ;;
    log|logs) show_log "${2:-}" ;;
    start|stop|restart) svc_cmd "$1" ;;
    cert) cert_menu ;;
    core) core_menu ;;
    update) update_script ;;
    uninstall) uninstall_all ;;
    *) usage; return 1 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
  exit $?
fi
