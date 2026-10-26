#!/usr/bin/env bash
# Source module; loaded by sb.sh.
SCRIPT_URL="${SCRIPT_URL:-}"
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

# 域名|展示分类
SNI_CATALOG=(
  'addons.mozilla.org|Firefox 扩展'
  'dl-cdn.alpinelinux.org|Linux 镜像'
  'www.python.org|Python 官网'
  'pypi.org|Python 包仓库'
  'www.lovelive-anime.jp|日本动漫'
  'www.cathaypacific.com|航空公司'
  'www.u-tokyo.ac.jp|日本高校'
  'www.kyoto-u.ac.jp|日本高校'
  'www.nus.edu.sg|新加坡高校'
  'www.ntu.edu.sg|新加坡高校'
  'www.hku.hk|香港高校'
  'www.hkust.edu.hk|香港高校'
  'www.stanford.edu|美国高校'
  'www.mit.edu|美国高校'
  'www.harvard.edu|美国高校'
  'www.ox.ac.uk|英国高校'
  'www.cam.ac.uk|英国高校'
  'www.ethz.ch|瑞士高校'
  'www.unimelb.edu.au|澳洲高校'
  'deb.debian.org|Linux 镜像'
  'crates.io|Rust 包仓库'
  'static.rust-lang.org|Rust 软件分发'
  'rubygems.org|Ruby 包仓库'
  'www.cpan.org|Perl 包仓库'
  'cpan.org|Perl 包仓库'
  'formulae.brew.sh|Homebrew 元数据'
)
SNI_LIST=()
for sni_entry in "${SNI_CATALOG[@]}"; do SNI_LIST+=("${sni_entry%%|*}"); done
unset sni_entry

SNI_QUICK_LIST=(
  www.u-tokyo.ac.jp www.nus.edu.sg www.stanford.edu www.ox.ac.uk
  dl-cdn.alpinelinux.org www.python.org pypi.org addons.mozilla.org
  www.lovelive-anime.jp www.cathaypacific.com
)

NODE_VARS=(N_ID N_PROTO N_LPORT N_PPORT N_HOST N_DOMAIN N_SNI N_UUID N_PASS N_FLOW N_MUX
           N_PRIV N_PBK N_SID N_WSPATH N_CERTMODE N_CERT N_KEY N_INSECURE N_ACMEV
           N_OBFS N_HOP_PORTS N_HOP_INTERVAL N_METHOD N_NOTE N_CREATED)
