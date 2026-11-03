#!/usr/bin/env bash
# Run on the Ceph ADMIN node (bootstrap / _admin host), NOT on K8s.
# Creates RBD pool (optional) + CephX client for CSI. CephX = keys only; no images.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
# Do not require K8s conf fields beyond pool/user — allow CEPH-only run with CONF
if [ -f "${CONF:-}" ]; then
  # shellcheck source=/dev/null
  . "$CONF"
fi
: "${RBD_POOL:=kubernetes}"
: "${CSI_USER_ID:=csi-rbd}"
: "${POOL_SIZE:=3}"
: "${POOL_MIN_SIZE:=2}"
# Kernel rbd on Ubuntu 24.04 (6.8) rejects 32-byte aes256k secrets.
# Default the CSI client to legacy 16-byte aes. Daemon keys are not touched.
# Set CSI_KEY_TYPE=aes256k only when every kubelet node runs Linux >= 7.0.
: "${CSI_KEY_TYPE:=aes}"
case "$CSI_KEY_TYPE" in
  aes|aes256k) ;;
  *) die "CSI_KEY_TYPE must be aes (kernel <= 6.8) or aes256k (kernel >= 7.0), got: $CSI_KEY_TYPE" ;;
esac
OUT_DIR=${OUT_DIR:-./secrets}
mkdir -p "$OUT_DIR"

CEPH=(sudo cephadm shell -- ceph)
# Fallback if ceph CLI works on host
if ! sudo cephadm shell -- ceph -s >/dev/null 2>&1; then
  if sudo ceph -s >/dev/null 2>&1; then
    CEPH=(sudo ceph)
  else
    echo "[FAIL] neither 'cephadm shell -- ceph' nor 'ceph' works on this host" >&2
    exit 1
  fi
fi

echo "== cluster health"
"${CEPH[@]}" -s | head -20

FSID=$("${CEPH[@]}" fsid)
echo "Ceph FSID (use as CLUSTER_ID in cluster.conf): $FSID"
echo "$FSID" > "$OUT_DIR/cluster-fsid.txt"

# Validate before touching the cluster: Ceph rejects min_size > size, and a
# non-numeric value would only show up as a confusing mismatch later.
case "$POOL_SIZE" in
  ''|*[!0-9]*) die "POOL_SIZE must be a positive integer, got: '${POOL_SIZE}'" ;;
esac
case "$POOL_MIN_SIZE" in
  ''|*[!0-9]*) die "POOL_MIN_SIZE must be a positive integer, got: '${POOL_MIN_SIZE}'" ;;
esac
POOL_SIZE=$((10#$POOL_SIZE))
POOL_MIN_SIZE=$((10#$POOL_MIN_SIZE))
[ "$POOL_SIZE" -ge 1 ] || die "POOL_SIZE must be >= 1, got: ${POOL_SIZE}"
[ "$POOL_MIN_SIZE" -ge 1 ] || die "POOL_MIN_SIZE must be >= 1, got: ${POOL_MIN_SIZE}"
[ "$POOL_MIN_SIZE" -le "$POOL_SIZE" ] \
  || die "POOL_MIN_SIZE (${POOL_MIN_SIZE}) must be <= POOL_SIZE (${POOL_SIZE}); for a single-OSD-host cluster set POOL_SIZE=1 POOL_MIN_SIZE=1"

# Print the value of `ceph osd pool get <pool> <key>` ("size: 3" -> "3").
pool_get() {
  "${CEPH[@]}" osd pool get "$RBD_POOL" "$1" | awk -v k="$1:" '$1 == k {print $2; exit}'
}

echo "== ensure pool $RBD_POOL (size=$POOL_SIZE min_size=$POOL_MIN_SIZE)"
if ! "${CEPH[@]}" osd pool ls | grep -qx "$RBD_POOL"; then
  "${CEPH[@]}" osd pool create "$RBD_POOL" 32 || die "osd pool create $RBD_POOL failed"
fi
# Tentacle returns EPERM for size 1 unless this flag is set. Do not hide that
# failure: a size-3 pool on one OSD host never becomes active.
size_args=(osd pool set "$RBD_POOL" size "$POOL_SIZE")
if [ "$POOL_SIZE" = 1 ]; then
  size_args+=(--yes-i-really-mean-it)
fi
"${CEPH[@]}" "${size_args[@]}" || die "ceph ${size_args[*]} failed (see the Ceph error above)"
# Set min_size after size: Ceph refuses min_size > the pool's current size.
"${CEPH[@]}" osd pool set "$RBD_POOL" min_size "$POOL_MIN_SIZE" \
  || die "ceph osd pool set $RBD_POOL min_size $POOL_MIN_SIZE failed (see the Ceph error above)"
got_size=$(pool_get size) || die "ceph osd pool get $RBD_POOL size failed"
got_min=$(pool_get min_size) || die "ceph osd pool get $RBD_POOL min_size failed"
[ "$got_size" = "$POOL_SIZE" ] || die "pool $RBD_POOL size is '${got_size:-empty}', want ${POOL_SIZE}"
[ "$got_min" = "$POOL_MIN_SIZE" ] || die "pool $RBD_POOL min_size is '${got_min:-empty}', want ${POOL_MIN_SIZE}"
echo "pool $RBD_POOL verified: size=${got_size} min_size=${got_min}"
"${CEPH[@]}" osd pool application enable "$RBD_POOL" rbd || true
# init for RBD (idempotent-ish)
"${CEPH[@]}" rbd pool init "$RBD_POOL" 2>/dev/null || true

echo "== CephX user client.${CSI_USER_ID} (key type ${CSI_KEY_TYPE}, kernel rbd)"
# Caps sufficient for provisioner + nodeplugin with a single Secret.
# Do NOT pass -o to paths like /tmp or OUT_DIR: under `cephadm shell` those are
# inside the container, so a later host-side cp fails with "No such file".
# Idempotent: an existing key of the requested type is kept; a different type
# is rotated. get-or-create refreshes caps. get-key / auth get rewrite host secrets.
KEYTYPE_PY="$HERE/cephx_key.py"
[ -f "$KEYTYPE_PY" ] || die "missing $KEYTYPE_PY"

# krbd on kernel 6.8 needs cipher aes still allowed. Do not drop aes256k
# and do not change auth_preferred_cipher (daemon keys stay on the cluster default).
ensure_aes_cipher() {
  [ "$CSI_KEY_TYPE" = aes ] || return 0
  local dump names
  dump=$("${CEPH[@]}" mon dump --format json)
  names=$(printf '%s' "$dump" | python3 "$KEYTYPE_PY" ciphers)
  if [ "$names" = "MISSING" ]; then
    echo "mon dump has no auth_allowed_ciphers; assuming a legacy aes-only cluster"
    return 0
  fi
  echo "auth_allowed_ciphers: ${names:-<empty>}"
  case ",$names," in
    *,aes,*) return 0 ;;
  esac
  local new="aes,aes256k"
  [ -n "$names" ] && new="${names},aes"
  echo "adding aes to auth_allowed_ciphers ($new) for kernel rbd"
  "${CEPH[@]}" mon set auth_allowed_ciphers "$new"
  # Monitors reject the new cipher for a few seconds after the set.
  sleep 3
}

# Retry when the mon briefly (or by config) refuses a legacy aes key.
# On a hard "insecure key" refusal, allow creating aes once: kernel 6.8
# cannot map aes256k. auth_preferred_cipher is left unchanged.
run_auth() {
  local attempt err
  err=$(mktemp "${OUT_DIR}/.auth.XXXXXX")
  chmod 600 "$err"
  for attempt in 1 2 3 4 5 6; do
    if "$@" >"$err" 2>&1; then
      rm -f "$err"
      return 0
    fi
    if grep -Eqi 'insecure key' "$err"; then
      warn "mon rejected ${CSI_KEY_TYPE} key (attempt ${attempt}): $(tr '\n' ' ' < "$err")"
      warn "setting mon_auth_allow_insecure_key=true so this CSI client can use aes"
      warn "AUTH_INSECURE_KEYS_CREATABLE / AUTH_INSECURE_CLIENT_KEY_TYPE for client.${CSI_USER_ID} are expected"
      "${CEPH[@]}" config set mon mon_auth_allow_insecure_key true
      sleep 3
      continue
    fi
    warn "auth command failed (attempt ${attempt}): $(tr '\n' ' ' < "$err")"
    sleep 2
  done
  cat "$err" >&2
  rm -f "$err"
  die "ceph auth command failed: $*"
}

decode_key_line() {
  python3 "$KEYTYPE_PY" decode "$1"
}

lookup_dump_type() {
  local json
  if ! json=$("${CEPH[@]}" auth dump-keys --format json 2>/dev/null); then
    printf ''
    return 0
  fi
  printf '%s' "$json" | python3 "$KEYTYPE_PY" entity "client.${CSI_USER_ID}"
}

ensure_aes_cipher

ENTITY="client.${CSI_USER_ID}"
ROTATED=0
CAPS_OSD="profile rbd pool=${RBD_POOL}, profile rbd pool=kubernetes"
if "${CEPH[@]}" auth get "$ENTITY" >/dev/null 2>&1; then
  CURRENT_KEY=$("${CEPH[@]}" auth get-key "$ENTITY" | tr -d ' \n\r\t')
  [ -n "$CURRENT_KEY" ] || die "empty key from auth get-key $ENTITY"
  read -r CUR_TYPE CUR_LEN <<<"$(decode_key_line "$CURRENT_KEY")"
  DUMP_TYPE=$(lookup_dump_type || true)
  if [ -n "$DUMP_TYPE" ] && [ "$DUMP_TYPE" != "$CUR_TYPE" ]; then
    die "dump-keys says ${DUMP_TYPE} but the key blob decodes as ${CUR_TYPE} len ${CUR_LEN}; not rotating"
  fi
  echo "existing $ENTITY key type ${CUR_TYPE} secret_len ${CUR_LEN}"
  if [ "$CUR_TYPE" != "$CSI_KEY_TYPE" ]; then
    echo "rotating $ENTITY ${CUR_TYPE} -> ${CSI_KEY_TYPE} (previous key stops working immediately)"
    run_auth "${CEPH[@]}" auth rotate "--key-type=${CSI_KEY_TYPE}" "$ENTITY"
    ROTATED=1
  fi
else
  echo "creating $ENTITY --key-type=${CSI_KEY_TYPE}"
  run_auth "${CEPH[@]}" auth get-or-create "--key-type=${CSI_KEY_TYPE}" "$ENTITY" \
    mon 'profile rbd' \
    mgr 'allow rw' \
    osd "$CAPS_OSD"
fi

# Refresh caps. Omitting --key-type keeps the key we just created or rotated.
run_auth "${CEPH[@]}" auth get-or-create "$ENTITY" \
  mon 'profile rbd' \
  mgr 'allow rw' \
  osd "$CAPS_OSD"

# Key for K8s Secret (host path)
KEY=$("${CEPH[@]}" auth get-key "$ENTITY" | tr -d ' \n\r\t')
[ -n "$KEY" ] || die "empty key from auth get-key $ENTITY"
read -r GOT_TYPE GOT_LEN <<<"$(decode_key_line "$KEY")"
DUMP_TYPE=$(lookup_dump_type || true)
if [ -n "$DUMP_TYPE" ] && [ "$DUMP_TYPE" != "$GOT_TYPE" ]; then
  die "dump-keys says ${DUMP_TYPE} but the new key blob decodes as ${GOT_TYPE} len ${GOT_LEN}"
fi
if [ "$GOT_TYPE" != "$CSI_KEY_TYPE" ]; then
  die "$ENTITY key type is ${GOT_TYPE} (secret_len ${GOT_LEN}), want ${CSI_KEY_TYPE}"
fi
if [ "$CSI_KEY_TYPE" = aes ] && [ "$GOT_LEN" != 16 ]; then
  die "aes secret length is ${GOT_LEN}; kernel 6.8 krbd accepts 16 bytes"
fi
printf '%s\n' "$KEY" > "$OUT_DIR/${CSI_USER_ID}.key"
chmod 600 "$OUT_DIR/${CSI_USER_ID}.key"

# Full keyring on host via stdout redirect (not container -o /tmp)
"${CEPH[@]}" auth get "$ENTITY" > "$OUT_DIR/client.${CSI_USER_ID}.keyring"
chmod 600 "$OUT_DIR/client.${CSI_USER_ID}.keyring"
chmod 600 "$OUT_DIR"/* 2>/dev/null || true

ROTATE_NOTE=""
if [ "$ROTATED" = 1 ]; then
  ROTATE_NOTE="  ROTATED:        previous ${ENTITY} key is invalid. Copy the new key before apply."
fi

cat <<MSG

Done.
  FSID:           $FSID   → set CLUSTER_ID in K8s cluster.conf
  Pool:           $RBD_POOL
  CephX user:     ${ENTITY}  (Secret userID=${CSI_USER_ID})
  Key type:       ${GOT_TYPE} secret_len=${GOT_LEN}  (kernel rbd / mounter rbd)
  Key file:       $OUT_DIR/${CSI_USER_ID}.key
  Monitors:       use CEPH_MON_VIP (e.g. 10.250.0.10:6789) — not individual MONs
${ROTATE_NOTE}
Copy $OUT_DIR/${CSI_USER_ID}.key to the K8s node and set CSI_USER_KEY_FILE in cluster.conf.
An aes CSI key is expected to raise AUTH_INSECURE_CLIENT_KEY_TYPE for ${ENTITY} only.
That key is what Ubuntu 24.04 kernel 6.8 can install for krbd. Daemon keys are unchanged.
Linux >= 7.0 nodes can set CSI_KEY_TYPE=aes256k and re-run this script.
MSG
