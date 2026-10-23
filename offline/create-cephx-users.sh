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

echo "== ensure pool $RBD_POOL (size=$POOL_SIZE min_size=$POOL_MIN_SIZE)"
if ! "${CEPH[@]}" osd pool ls | grep -qx "$RBD_POOL"; then
  "${CEPH[@]}" osd pool create "$RBD_POOL" 32
fi
"${CEPH[@]}" osd pool set "$RBD_POOL" size "$POOL_SIZE" || true
"${CEPH[@]}" osd pool set "$RBD_POOL" min_size "$POOL_MIN_SIZE" || true
"${CEPH[@]}" osd pool application enable "$RBD_POOL" rbd || true
# init for RBD (idempotent-ish)
"${CEPH[@]}" rbd pool init "$RBD_POOL" 2>/dev/null || true

echo "== CephX user client.${CSI_USER_ID}"
# Caps sufficient for provisioner + nodeplugin with a single Secret.
# Do NOT pass -o to paths like /tmp or OUT_DIR: under `cephadm shell` those are
# inside the container, so a later host-side cp fails with "No such file".
# Idempotent: get-or-create refreshes caps; get-key / auth get rewrite host secrets.
"${CEPH[@]}" auth get-or-create "client.${CSI_USER_ID}" \
  mon 'profile rbd' \
  mgr 'allow rw' \
  osd "profile rbd pool=${RBD_POOL}, profile rbd pool=kubernetes"

# Key for K8s Secret (host path)
KEY=$("${CEPH[@]}" auth get-key "client.${CSI_USER_ID}")
[ -n "$KEY" ] || die "empty key from auth get-key client.${CSI_USER_ID}"
printf '%s\n' "$KEY" > "$OUT_DIR/${CSI_USER_ID}.key"
chmod 600 "$OUT_DIR/${CSI_USER_ID}.key"

# Full keyring on host via stdout redirect (not container -o /tmp)
"${CEPH[@]}" auth get "client.${CSI_USER_ID}" > "$OUT_DIR/client.${CSI_USER_ID}.keyring"
chmod 600 "$OUT_DIR/client.${CSI_USER_ID}.keyring"
chmod 600 "$OUT_DIR"/* 2>/dev/null || true

cat <<MSG

Done.
  FSID:           $FSID   → set CLUSTER_ID in K8s cluster.conf
  Pool:           $RBD_POOL
  CephX user:     client.${CSI_USER_ID}  (Secret userID=${CSI_USER_ID})
  Key file:       $OUT_DIR/${CSI_USER_ID}.key
  Monitors:       use CEPH_MON_VIP (e.g. 10.250.0.10:6789) — not individual MONs

Copy $OUT_DIR/${CSI_USER_ID}.key to the K8s node and set CSI_USER_KEY_FILE in cluster.conf.
MSG
