#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF=${CONF:-$HERE/cluster.conf}

log()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%T)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"; }


# Parse registry from CLI before load_conf.
# Effective priority after load_conf: CLI > env REGISTRY > NODE_IP:REGISTRY_PORT
# Supports: --registry HOST:PORT | --registry=HOST:PORT | HOST:PORT
# When CLI provides a value, exports REGISTRY for load_conf to keep.
# Leftover args land in REGISTRY_CLI_REST (bash array).
parse_registry_cli() {
  REGISTRY_CLI_REST=()
  local got=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'USAGE' >&2
Usage: script [HOST:PORT] | [--registry HOST:PORT]
  CLI registry overrides env REGISTRY and cluster.conf (NODE_IP:REGISTRY_PORT).
  With no CLI/env, REGISTRY is derived from cluster.conf as before.
USAGE
        exit 0
        ;;
      --registry)
        [ $# -ge 2 ] || die "--registry needs HOST:PORT"
        got="$2"
        shift 2
        ;;
      --registry=*)
        got="${1#--registry=}"
        shift
        ;;
      *)
        if [ -z "$got" ] && [[ "$1" == *:* ]] && [[ ! "$1" == -* ]]; then
          got="$1"
          shift
        else
          REGISTRY_CLI_REST+=("$1")
          shift
        fi
        ;;
    esac
  done
  if [ -n "$got" ]; then
    [[ "$got" == *:* ]] || die "registry must look like HOST:PORT (got: $got)"
    export REGISTRY="$got"
  fi
}

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
  # Smoke pod image — match Fast_deploy_k8s / kubeadm 1.35.7 PauseVersion
  : "${PAUSE_TAG:=3.10.1}"
  : "${PAUSE_IMAGE:=pause:${PAUSE_TAG}}"
  # Prefer already-set REGISTRY (CLI via parse_registry_cli, or env); else conf
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

# normalize_timeout VALUE NAME: echo VALUE (bare number gets "s").
# Empty, zero (0, 0s, 00m) or not ^[0-9]+[smh]?$ -> die.
normalize_timeout() {
  local v=$1 name=${2:-timeout}
  [ -n "$v" ] || die "$name is empty (expected ^[0-9]+[smh]?$, > 0)"
  [[ $v =~ ^[0-9]+[smh]?$ ]] || die "invalid $name '$v' (expected ^[0-9]+[smh]?$)"
  [[ $v =~ ^0+[smh]?$ ]] && die "$name '$v' must be > 0"
  case "$v" in *[0-9]) v="${v}s" ;; esac
  printf '%s\n' "$v"
}
