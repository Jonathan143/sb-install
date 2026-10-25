#!/usr/bin/env bash
# Real archives and certificates, with isolated paths and simulated services.
source "$(dirname "$0")/../sb.sh"
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
fixture() {
  SB_DIR="$ROOT/$1"; CONF_DIR="$SB_DIR/conf.d"; META_DIR="$SB_DIR/meta"
  CERT_DIR="$SB_DIR/certs"; BACKUP_DIR="$SB_DIR/backup"; SB_WORKDIR="$SB_DIR/work"
  SB_MODE=takeover
  mkdir -p "$CONF_DIR" "$META_DIR" "$CERT_DIR/example.test" "$BACKUP_DIR"
  meta_reset
  N_ID=1 N_PROTO=ss N_LPORT=24443 N_PPORT=34443 N_HOST=example.test
  N_METHOD=aes-128-gcm N_PASS=original N_NOTE=original
  meta_save && write_node_conf || fail fixture
  printf 'original certificate\n' > "$CERT_DIR/example.test/fullchain.pem"
  printf 'original key\n' > "$CERT_DIR/example.test/key.pem"
}
svc() { return 1; }
sleep() { :; }
fw_open() { :; }
fw_close() { :; }
show_node() { :; }
has_systemd() { return 1; }
write_service() { :; }

fixture snapshot
snapshot || fail snapshot
first=$LAST_SNAP
snapshot || fail 'second snapshot'
[[ $first != "$LAST_SNAP" && -s $first ]] || fail 'snapshots collide within one second'
(
  tar() { printf 'broken' > "$2"; return 1; }
  if snapshot; then fail 'failed archive creation accepted'; fi
  [[ -z $LAST_SNAP ]] || fail 'failed snapshot published'
) || exit 1

# Legacy backups remain usable without discarding certificates they never saved.
(
  fixture legacy
  LAST_SNAP="$BACKUP_DIR/legacy.tgz"
  tar -czf "$LAST_SNAP" -C "$SB_DIR" conf.d meta || fail 'legacy archive'
  printf 'renewed certificate\n' > "$CERT_DIR/example.test/fullchain.pem"
  restore_snapshot || fail 'legacy restore'
  [[ $(cat "$CERT_DIR/example.test/fullchain.pem") == 'renewed certificate' ]] || fail 'legacy restore changed certificates'
) || exit 1
meta_load 1
[[ $N_PASS == original ]] || fail 'failed snapshot changed metadata'

# A corrupt archive must be rejected before either live directory is touched.
printf 'corrupt archive\n' > "$BACKUP_DIR/broken.tgz"
LAST_SNAP="$BACKUP_DIR/broken.tgz"
if restore_snapshot > "$ROOT/corrupt-log" 2>&1; then fail 'corrupt restore succeeded'; fi
[[ -s $META_DIR/1.env && -s $CONF_DIR/01-ss.json ]] || fail 'corrupt restore deleted live data'
if grep -q '已回滚' "$ROOT/corrupt-log"; then fail 'false rollback message'; fi

LAST_SNAP=$first
printf 'changed\n' > "$CERT_DIR/example.test/fullchain.pem"
printf 'changed\n' > "$META_DIR/1.env"
restore_snapshot || fail 'valid restore'
meta_load 1
[[ $N_PASS == original && $(cat "$CERT_DIR/example.test/fullchain.pem") == 'original certificate' ]] || fail 'incomplete restore'

# A failed directory replacement must put back the state preceding the restore.
(
  printf 'current metadata\n' > "$META_DIR/1.env"
  printf 'current config\n' > "$CONF_DIR/01-ss.json"
  mv() {
    [[ $1 != */.restore.*/new/meta ]] || return 1
    command mv "$@"
  }
  if restore_snapshot; then fail 'directory replacement failure accepted'; fi
  [[ $(cat "$META_DIR/1.env") == 'current metadata' && $(cat "$CONF_DIR/01-ss.json") == 'current config' ]] || fail 'failed replacement lost current data'
) || exit 1

# Every mutating entry point must stop when its snapshot cannot be created.
for operation in add edit delete; do
  (
    fixture "$operation-snapshot-failure"
    snapshot() { return 1; }
    need_core() { :; }
    confirm() { return 0; }
    pick_port() { PICKED=25555; }
    ask_pub_port() { echo 35555; }
    ask_choice() { [[ $operation == add ]] && echo 7 || echo 6; }
    ask() { fail 'prompt continued after snapshot failure'; }
    if "${operation}_node" 1; then fail "$operation accepted snapshot failure"; fi
    meta_load 1
    [[ $N_PASS == original && $N_NOTE == original && -s $CONF_DIR/01-ss.json ]] || fail "$operation changed state"
    [[ ! -e $META_DIR/2.env ]] || fail 'add persisted without backup'
  ) || exit 1
done

# Configuration activation failures restore files and restart the original service.
for case_name in restart-failure export-failure; do
  (
    fixture "apply-$case_name"
    SB_BIN="$ROOT/accept-core"
    printf '#!/bin/sh\nexit 0\n' > "$SB_BIN"; chmod 755 "$SB_BIN"
    ask_choice() { echo 1; }; pick_port() { PICKED=25555; }; ask_pub_port() { echo 35555; }
    svc() {
      echo "$1" >> "$SB_DIR/events"
      [[ $case_name != restart-failure || $1 != restart || $(jq -r '.inbounds[0].listen_port' "$CONF_DIR/01-ss.json") == 24443 ]]
    }
    if [[ $case_name == export-failure ]]; then write_nodes_txt() { return 1; }; fi
    if edit_node 1; then fail 'failed activation accepted'; fi
    meta_load 1
    [[ $N_LPORT == 24443 && $(jq -r '.inbounds[0].listen_port' "$CONF_DIR/01-ss.json") == 24443 ]] || fail 'activation rollback lost configuration'
    [[ $(grep -c '^restart$' "$SB_DIR/events") == 2 ]] || fail 'old service not restarted'
  ) || exit 1
done

# A failed export preserves the previous links and does not leak node iteration state.
fixture export
write_nodes_txt || fail 'initial export'
cp "$SB_DIR/nodes.txt" "$ROOT/links-before"
N_ID=99
write_nodes_txt || fail export
[[ $N_ID == 99 ]] || fail 'export changed selected node'
(
  node_link() { return 1; }
  if write_nodes_txt; then fail 'failed link export accepted'; fi
  cmp "$SB_DIR/nodes.txt" "$ROOT/links-before" || fail 'failed export replaced links'
) || exit 1

# Self-signed certificates neither overwrite shared DNS certificates nor survive rollback.
fixture certificates
snapshot || fail snapshot
N_DOMAIN=example.test
cert_self || fail 'self certificate'
first_cert=$N_CERT
openssl x509 -in "$first_cert" -noout >/dev/null || fail 'invalid certificate'
cert_self || fail 'second self certificate'
[[ $first_cert != "$N_CERT" && $(cat "$CERT_DIR/example.test/fullchain.pem") == 'original certificate' ]] || fail 'shared certificate overwritten'
restore_snapshot || fail 'certificate rollback'
[[ ! -e $first_cert && ! -e $N_CERT && $(cat "$CERT_DIR/example.test/key.pem") == 'original key' ]] || fail 'certificate rollback incomplete'

for operation in add edit; do
  (
    fixture "$operation-cancel"
    N_PROTO=ws N_UUID=00000000-0000-4000-8000-000000000001 N_WSPATH=/ws
    N_DOMAIN=example.test N_CERTMODE=dns N_INSECURE=0
    N_CERT="$CERT_DIR/example.test/fullchain.pem" N_KEY="$CERT_DIR/example.test/key.pem"
    meta_save; write_node_conf || fail 'TLS fixture'
    cp "$META_DIR/1.env" "$ROOT/before.env"
    need_core() { :; }; gen_uuid() { echo 00000000-0000-4000-8000-000000000002; }
    pick_port() { PICKED=25555; }; ask_pub_port() { echo 35555; }
    ask_choice() { echo 2; }; confirm() { return 1; }; detect_ip() { echo 192.0.2.1; }
    cert_flow() { N_DOMAIN=example.test; cert_self || return 1; [[ $operation == add ]]; }
    ask() { return 1; }
    if "${operation}_node" 1; then fail 'cancellation accepted'; fi
    cmp "$META_DIR/1.env" "$ROOT/before.env" || fail 'cancel changed metadata'
    [[ $(cat "$CERT_DIR/example.test/fullchain.pem") == 'original certificate' ]] || fail 'cancel changed shared cert'
    [[ -z $(find "$CERT_DIR" -type d -name 'self.*') ]] || fail 'cancel left new certificates'
  ) || exit 1
done

for case_name in coexist takeover stop-failure; do
  (
    fixture "delete-$case_name"
    SB_BIN="$ROOT/accept-core"
    printf '#!/bin/sh\nexit 0\n' > "$SB_BIN"; chmod 755 "$SB_BIN"
    if [[ $case_name == coexist ]]; then
      SB_MODE=coexist
      printf '{"inbounds":[{"tag":"legacy"}]}\n' > "$SB_DIR/config.json"
    fi
    confirm() { return 0; }
    svc() { echo "$1" >> "$SB_DIR/events"; [[ ! ( $case_name == stop-failure && $1 == stop ) ]]; }
    if [[ $case_name == stop-failure ]]; then
      if delete_node 1; then fail 'stop failure accepted'; fi
      [[ -s $META_DIR/1.env && -s $CONF_DIR/01-ss.json ]] || fail 'failed delete not restored'
    else
      delete_node 1 || fail 'delete failed'
      [[ ! -e $META_DIR/1.env ]] || fail 'node not deleted'
      if [[ $case_name == coexist ]]; then
        grep -q restart "$SB_DIR/events" || fail 'legacy service not reloaded'
        if grep -q stop "$SB_DIR/events"; then fail 'coexisting service stopped'; fi
        [[ -s $SB_DIR/config.json ]] || fail 'legacy config changed'
      else grep -q stop "$SB_DIR/events" || fail 'empty takeover not stopped'; fi
    fi
  ) || exit 1
done
echo 'PASS: snapshot failures, safe restoration, certificate isolation and node transactions'
