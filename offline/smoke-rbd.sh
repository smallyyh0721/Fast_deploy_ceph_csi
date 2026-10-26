#!/usr/bin/env bash
# Apply RBD CSI smoke PVC+Pod and wait for Bound.
# Registry priority: CLI > env REGISTRY > cluster.conf
# Examples:
#   sudo ./smoke-rbd.sh
#   sudo ./smoke-rbd.sh 192.168.180.16:5000
#   sudo ./smoke-rbd.sh --registry 192.168.180.16:5000
#   sudo ./smoke-rbd.sh --pod-timeout 300s
# Pod Ready timeout priority: --pod-timeout > env/cluster.conf SMOKE_POD_TIMEOUT > 180s
set -euo pipefail
. "$(dirname "$0")/lib.sh"
parse_registry_cli "$@"
POD_TIMEOUT_CLI=""
set -- ${REGISTRY_CLI_REST[@]+"${REGISTRY_CLI_REST[@]}"}
while [ $# -gt 0 ]; do
  case "$1" in
    --pod-timeout) [ $# -ge 2 ] || die "--pod-timeout needs a value"; POD_TIMEOUT_CLI=$2; shift 2 ;;
    --pod-timeout=*) POD_TIMEOUT_CLI=${1#*=}; shift ;;
    *) die "unknown args: $*" ;;
  esac
done
need_root; load_conf
POD_TIMEOUT=${POD_TIMEOUT_CLI:-${SMOKE_POD_TIMEOUT:-180s}}
case "$POD_TIMEOUT" in *[smh]) ;; *[0-9]) POD_TIMEOUT="${POD_TIMEOUT}s" ;; esac
export_kubeconfig

OUT="$HERE/manifests/generated"
SMOKE_YAML="$OUT/90-smoke-pvc-pod.yaml"
PAUSE_REF="${REGISTRY}/${PAUSE_IMAGE}"

ensure_pause() {
  local ok=0
  if curl -fsS "http://${REGISTRY}/v2/pause/tags/list" 2>/dev/null | grep -q "\"${PAUSE_TAG}\""; then
    ok=1
  fi
  if ctr -n k8s.io images ls -q 2>/dev/null | grep -Eq "(^|/)${PAUSE_REF}$|registry.k8s.io/pause:${PAUSE_TAG}$|/pause:${PAUSE_TAG}$"; then
    ok=1
  fi
  if [ "$ok" -ne 1 ]; then
    die "pause image not found as ${PAUSE_REF}
  Check:
    curl -s http://${REGISTRY}/v2/_catalog
    curl -s http://${REGISTRY}/v2/pause/tags/list
    ctr -n k8s.io images ls | grep pause
  Fix: run Fast_deploy_k8s setup-registry.sh (ships pause:${PAUSE_TAG}), or rebuild CSI bundle + sudo ./load-images.sh [--registry ...]"
  fi
  log "pause OK: ${PAUSE_REF}"
}

if [ ! -f "$SMOKE_YAML" ]; then
  log "missing $SMOKE_YAML — rendering with RENDER_ONLY=1"
  RENDER_ONLY=1 "$HERE/apply-rbd-csi.sh" --registry "$REGISTRY"
fi
[ -f "$SMOKE_YAML" ] || die "still missing $SMOKE_YAML after render"

# Ensure rendered yaml uses current REGISTRY/PAUSE (re-render if REGISTRY changed)
if ! grep -q "image: ${PAUSE_REF}$" "$SMOKE_YAML" 2>/dev/null; then
  log "smoke yaml registry/tag mismatch — re-render"
  RENDER_ONLY=1 "$HERE/apply-rbd-csi.sh" --registry "$REGISTRY"
fi

ensure_pause

log "kubectl apply -f $SMOKE_YAML"
kubectl apply -f "$SMOKE_YAML"

log "wait for PVC Bound (up to 120s)"
if ! kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/rbd-smoke-pvc --timeout=120s; then
  warn "PVC not Bound yet"
  kubectl describe pvc rbd-smoke-pvc || true
  kubectl get events -A --field-selector involvedObject.name=rbd-smoke-pvc --sort-by=.lastTimestamp | tail -20 || true
  die "PVC rbd-smoke-pvc not Bound"
fi

kubectl get pvc rbd-smoke-pvc -o wide
kubectl describe pvc rbd-smoke-pvc | tail -40
log "wait for Pod Ready (up to ${POD_TIMEOUT})"
if ! kubectl wait --for=condition=Ready pod/rbd-smoke-pod --timeout="$POD_TIMEOUT"; then
  warn "Pod not Ready"
  kubectl get pod rbd-smoke-pod -o wide || true
  kubectl describe pod rbd-smoke-pod || true
  kubectl get events --field-selector involvedObject.name=rbd-smoke-pod --sort-by=.lastTimestamp || true
  die "pod rbd-smoke-pod not Ready within ${POD_TIMEOUT}"
fi
kubectl get pod rbd-smoke-pod -o wide
log "smoke apply done. PVC Bound and Pod Running (pause mounts /mnt/rbd)."
