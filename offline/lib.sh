#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF=${CONF:-$HERE/cluster.conf}

log()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%T)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"; }

load_conf() {
  [ -f "$CONF" ] || die "config $CONF not found (cp cluster.conf.example cluster.conf)"
  # shellcheck source=/dev/null
  . "$CONF"
  : "${BUNDLE_DIR:?}" "${NODE_IP:?}" "${NAMESPACE:?}" "${CEPH_MON_VIP:?}" "${CLUSTER_ID:?}" "${RBD_POOL:?}"
  : "${REGISTRY_PORT:=5000}" "${PROVISIONER_REPLICAS:=1}"
  : "${CSI_USER_ID:=csi-rbd}" "${STORAGE_CLASS_NAME:=csi-rbd-sc}"
  : "${SC_FSTYPE:=ext4}" "${SC_RECLAIM_POLICY:=Delete}" "${SC_ALLOW_EXPANSION:=true}"
  : "${CEPHCSI_IMAGE:=cephcsi/cephcsi:v3.18.1}"
  : "${CSI_PROVISIONER_IMAGE:=sig-storage/csi-provisioner:v6.3.0}"
  : "${CSI_ATTACHER_IMAGE:=sig-storage/csi-attacher:v4.13.0}"
  : "${CSI_RESIZER_IMAGE:=sig-storage/csi-resizer:v2.2.1}"
  : "${CSI_SNAPSHOTTER_IMAGE:=sig-storage/csi-snapshotter:v8.6.0}"
  : "${CSI_REGISTRAR_IMAGE:=sig-storage/csi-node-driver-registrar:v2.18.0}"
  REGISTRY="${REGISTRY:-${NODE_IP}:${REGISTRY_PORT}}"
  if [ -f "$BUNDLE_DIR/images/TAGS.env" ]; then
    # shellcheck source=/dev/null
    . "$BUNDLE_DIR/images/TAGS.env"
  fi
}

export_kubeconfig() {
  if [ -z "${KUBECONFIG:-}" ]; then
    if [ -f /etc/kubernetes/admin.conf ]; then
      export KUBECONFIG=/etc/kubernetes/admin.conf
    elif [ -f "$HOME/.kube/config" ]; then
      export KUBECONFIG="$HOME/.kube/config"
    else
      die "KUBECONFIG not set and no admin.conf found"
    fi
  fi
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
}
