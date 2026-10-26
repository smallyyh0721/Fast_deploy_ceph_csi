#!/usr/bin/env bash
# Apply RBD CSI smoke PVC+Pod, wait for PVC Bound, then for Pod Ready.
# Registry priority: CLI > env REGISTRY > cluster.conf
# Examples:
#   sudo ./smoke-rbd.sh
#   sudo ./smoke-rbd.sh 192.168.180.16:5000
#   sudo ./smoke-rbd.sh --registry 192.168.180.16:5000
#   sudo ./smoke-rbd.sh --pod-timeout 300s
# Pod Ready timeout priority: --pod-timeout > env SMOKE_POD_TIMEOUT > cluster.conf > 180s
# Timeout must match ^[0-9]+[smh]?$ (bare number = seconds). Empty/zero/invalid -> error.
# Plain sudo drops env vars: use sudo -E for SMOKE_POD_TIMEOUT, or --pod-timeout.
set -euo pipefail
usage() {
  cat <<'USAGE'
Usage: sudo ./smoke-rbd.sh [REGISTRY | --registry HOST:PORT] [--pod-timeout T]
  --pod-timeout T   Pod Ready wait, ^[0-9]+[smh]?$ (e.g. 180, 300s, 5m). Default 180s.
                    Also via env/cluster.conf SMOKE_POD_TIMEOUT. Empty, zero or invalid -> error.
  Precedence: CLI > env > cluster.conf > default. cluster.conf uses the
              ${VAR-default} form (e.g. SMOKE_POD_TIMEOUT="${SMOKE_POD_TIMEOUT-180s}"),
              so an env var set before running wins over the conf value.
  Note: plain sudo drops env vars. Use `SMOKE_POD_TIMEOUT=5m sudo -E ./smoke-rbd.sh`
        or pass --pod-timeout.
USAGE
}
. "$(dirname "$0")/lib.sh"
# Parse our own flags first (value-aware), so `--pod-timeout -h` is a bad timeout,
# not a help request. Remaining args go to parse_registry_cli.
POD_TIMEOUT_CLI=""; POD_TIMEOUT_CLI_SET=0; REST=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --pod-timeout) [ $# -ge 2 ] || die "--pod-timeout needs a value"; POD_TIMEOUT_CLI=$2; POD_TIMEOUT_CLI_SET=1; shift 2 ;;
    --pod-timeout=*) POD_TIMEOUT_CLI=${1#*=}; POD_TIMEOUT_CLI_SET=1; shift ;;
    --registry) REST+=("$1"); [ $# -lt 2 ] || REST+=("$2"); shift; [ $# -eq 0 ] || shift ;;
    *) REST+=("$1"); shift ;;
  esac
done
# Validate CLI value before root/conf checks so bad input fails fast.
if [ "$POD_TIMEOUT_CLI_SET" = 1 ]; then
  POD_TIMEOUT=$(normalize_timeout "$POD_TIMEOUT_CLI" --pod-timeout) || exit 1
fi
parse_registry_cli ${REST[@]+"${REST[@]}"}
[ "${#REGISTRY_CLI_REST[@]}" -eq 0 ] || die "unknown args: ${REGISTRY_CLI_REST[*]}"
need_root; load_conf
if [ "$POD_TIMEOUT_CLI_SET" = 1 ]; then
  :
elif [ -n "${SMOKE_POD_TIMEOUT+x}" ]; then
  POD_TIMEOUT=$(normalize_timeout "$SMOKE_POD_TIMEOUT" SMOKE_POD_TIMEOUT) || exit 1
else
  POD_TIMEOUT=180s
fi
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
