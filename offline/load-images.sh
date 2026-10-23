#!/usr/bin/env bash
# Load CSI image tars into containerd and push to the K8s local registry.
# Registry priority: CLI > env REGISTRY > cluster.conf (NODE_IP:REGISTRY_PORT)
# Examples:
#   sudo ./load-images.sh
#   sudo ./load-images.sh 192.168.180.16:5000
#   sudo ./load-images.sh --registry 192.168.180.16:5000
# Requires: Fast_deploy_k8s registry already running (k8s-local-registry / curl http://$REGISTRY/v2/).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
parse_registry_cli "$@"
[ "${#REGISTRY_CLI_REST[@]}" -eq 0 ] || die "unknown args: ${REGISTRY_CLI_REST[*]}"
need_root; load_conf
log "using registry: ${REGISTRY}"

IMGDIR="$BUNDLE_DIR/images"
[ -d "$IMGDIR" ] || die "$IMGDIR missing — extract the CSI bundle to BUNDLE_DIR"
command -v ctr >/dev/null 2>&1 || die "ctr not found (install containerd / Fast_deploy_k8s first)"

if ! curl -fsS "http://${REGISTRY}/v2/" >/dev/null 2>&1; then
  die "registry http://${REGISTRY}/v2/ not reachable — run Fast_deploy_k8s setup-registry.sh first"
fi

load_tar() {
  local tar="$1"
  [ -s "$tar" ] || die "missing image tar: $tar"
  log "ctr import $(basename "$tar")"
  ctr -n k8s.io images import "$tar" >/dev/null
}

tag_and_push() {
  local src="$1" dst="$2"
  log "tag $src -> $dst"
  ctr -n k8s.io images tag "$src" "$dst" >/dev/null 2>&1 || \
    ctr -n k8s.io images tag "docker.io/${src#docker.io/}" "$dst" >/dev/null 2>&1 || true
  # try common name variants
  if ! ctr -n k8s.io images ls -q | grep -qx "$dst"; then
    # find by short name
    local hit
    hit=$(ctr -n k8s.io images ls -q | grep -E "/${src##*/}$|${src}$" | head -1 || true)
    [ -n "$hit" ] || die "cannot find imported image for $src"
    ctr -n k8s.io images tag "$hit" "$dst"
  fi
  log "push $dst"
  ctr -n k8s.io images push --plain-http "$dst"
}

# Filenames produced by build-bundle.sh
load_tar "$IMGDIR/cephcsi-v3.18.1.tar"
load_tar "$IMGDIR/csi-provisioner-v6.3.0.tar"
load_tar "$IMGDIR/csi-attacher-v4.13.0.tar"
load_tar "$IMGDIR/csi-resizer-v2.2.1.tar"
load_tar "$IMGDIR/csi-snapshotter-v8.6.0.tar"
load_tar "$IMGDIR/csi-node-driver-registrar-v2.18.0.tar"
# pause for smoke-rbd.sh (also shipped by Fast_deploy_k8s); optional if older CSI bundles
if [ -s "$IMGDIR/pause-${PAUSE_TAG}.tar" ]; then
  load_tar "$IMGDIR/pause-${PAUSE_TAG}.tar"
else
  warn "pause-${PAUSE_TAG}.tar missing in CSI bundle — smoke needs ${REGISTRY}/pause:${PAUSE_TAG} from Fast_deploy_k8s or a rebuilt CSI bundle"
fi

# Source refs as saved by podman (may include docker.io/ or registry.k8s.io/)
tag_and_push "quay.io/cephcsi/cephcsi:v3.18.1"                         "${REGISTRY}/${CEPHCSI_IMAGE}"
tag_and_push "registry.k8s.io/sig-storage/csi-provisioner:v6.3.0"       "${REGISTRY}/${CSI_PROVISIONER_IMAGE}"
tag_and_push "registry.k8s.io/sig-storage/csi-attacher:v4.13.0"         "${REGISTRY}/${CSI_ATTACHER_IMAGE}"
tag_and_push "registry.k8s.io/sig-storage/csi-resizer:v2.2.1"           "${REGISTRY}/${CSI_RESIZER_IMAGE}"
tag_and_push "registry.k8s.io/sig-storage/csi-snapshotter:v8.6.0"       "${REGISTRY}/${CSI_SNAPSHOTTER_IMAGE}"
tag_and_push "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.18.0" "${REGISTRY}/${CSI_REGISTRAR_IMAGE}"
if ctr -n k8s.io images ls -q | grep -Eq "pause:${PAUSE_TAG}$|/pause:${PAUSE_TAG}$|registry.k8s.io/pause:${PAUSE_TAG}$"; then
  tag_and_push "registry.k8s.io/pause:${PAUSE_TAG}" "${REGISTRY}/${PAUSE_IMAGE}"
else
  warn "pause:${PAUSE_TAG} not in containerd — skip push; check: ctr -n k8s.io images ls | grep pause"
fi

log "catalog:"
curl -fsS "http://${REGISTRY}/v2/_catalog" || true
echo
log "done. Images pushed to ${REGISTRY}"
