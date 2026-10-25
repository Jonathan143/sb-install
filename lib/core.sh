#!/usr/bin/env bash
# Source module; loaded by sb.sh.
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
  if [[ -z $ver ]]; then
    ver=$(ask "无法获取最新版本，请手动输入版本号（如 1.12.0）") || return 1
  fi
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

write_service_file() {
  local file=$1 mode=$2 tmp
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  if ! cat > "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"; err "服务定义写入失败，原文件未替换"; return 1
  fi
}

write_service() {
  sb_args
  mkdir -p "$SB_WORKDIR" || return 1
  if has_systemd; then
    write_service_file "/etc/systemd/system/$SB_SERVICE.service" 644 <<EOF
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
    [[ $? == 0 ]] || return 1
    systemctl daemon-reload
  elif command -v rc-service >/dev/null; then
    write_service_file "/etc/init.d/$SB_SERVICE" 755 <<EOF
#!/sbin/openrc-run
name="sing-box"
command="$SB_BIN"
command_args="${SB_ARGS[*]} run"
command_background=true
pidfile="/run/$SB_SERVICE.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() { need net; }
EOF
    [[ $? == 0 ]] || return 1
    return 0
  else
    warn "未检测到 systemd 或 OpenRC，需要自行管理 sing-box 进程"
    return 1
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
