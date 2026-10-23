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

SNI_LIST=(
  addons.mozilla.org dl-cdn.alpinelinux.org www.python.org pypi.org
  www.samsung.com www.nvidia.com www.intel.com www.sony.com
  www.visa.com www.mastercard.com www.paypal.com www.stanford.edu
  www.lovelive-anime.jp www.cathaypacific.com www.singaporeair.com
)

NODE_VARS=(N_ID N_PROTO N_LPORT N_PPORT N_HOST N_DOMAIN N_SNI N_UUID N_PASS N_FLOW N_MUX
           N_PRIV N_PBK N_SID N_WSPATH N_CERTMODE N_CERT N_KEY N_INSECURE N_ACMEV
           N_OBFS N_METHOD N_NOTE N_CREATED)
