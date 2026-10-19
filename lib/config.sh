#!/usr/bin/env bash
# Source module; loaded by sb.sh.
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
meta_reset() { local v; for v in "${NODE_VARS[@]}"; do printf -v "$v" '%s' ''; done; N_MUX=0; }
meta_load() { local f="$META_DIR/$1.env"; [[ $1 =~ ^[0-9]+$ && -f $f ]] || return 1; meta_reset; . "$f"; }
meta_save() {
  local v f="$META_DIR/$N_ID.env"
  { for v in "${NODE_VARS[@]}"; do printf '%s=%q\n' "$v" "${!v}"; done; } > "$f"
  chmod 600 "$f"
}
list_ids() { ls "$META_DIR" 2>/dev/null | sed -n 's/\.env$//p' | sort -n; }
next_id() { local i=1; while [[ -f $META_DIR/$i.env ]]; do i=$((i+1)); done; echo "$i"; }
conf_file() { printf '%s/%02d-%s.json' "$CONF_DIR" "$N_ID" "$N_PROTO"; }
