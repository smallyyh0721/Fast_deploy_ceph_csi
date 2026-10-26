#!/usr/bin/env bash
# Render RBD CSI manifests (local registry + VIP + secrets) and kubectl apply.
# Registry priority: CLI > env REGISTRY > cluster.conf (NODE_IP:REGISTRY_PORT)
# Examples:
#   sudo ./apply-rbd-csi.sh
#   sudo ./apply-rbd-csi.sh 192.168.180.16:5000
#   sudo ./apply-rbd-csi.sh --registry 192.168.180.16:5000
# Prerequisites: load-images.sh done; CephX key file present; kubectl works.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
parse_registry_cli "$@"
[ "${#REGISTRY_CLI_REST[@]}" -eq 0 ] || die "unknown args: ${REGISTRY_CLI_REST[*]}"
need_root; load_conf
log "using registry: ${REGISTRY}"
RENDER_ONLY=${RENDER_ONLY:-0}
if [ "$RENDER_ONLY" != "1" ]; then
  export_kubeconfig
fi

VENDOR=${VENDOR:-$BUNDLE_DIR/vendor}
[ -d "$VENDOR" ] || VENDOR="$HERE/../vendor"
[ -d "$VENDOR" ] || die "vendor YAMLs not found at $BUNDLE_DIR/vendor or $HERE/../vendor"

OUT="$HERE/manifests/generated"
mkdir -p "$OUT" "$HERE/manifests"

[ -f "${CSI_USER_KEY_FILE:?}" ] || die "CSI_USER_KEY_FILE missing: $CSI_USER_KEY_FILE (run create-cephx-users.sh on Ceph)"
USER_KEY=$(tr -d ' \n\r\t' < "$CSI_USER_KEY_FILE")
[ -n "$USER_KEY" ] || die "empty key in $CSI_USER_KEY_FILE"
if [ "$CLUSTER_ID" = "REPLACE_WITH_CEPH_FSID" ] || [ -z "$CLUSTER_ID" ]; then
  die "set CLUSTER_ID to \`ceph fsid\` output in cluster.conf"
fi

REG="$REGISTRY"
NS="$NAMESPACE"

rewrite_images() {
  # stdin YAML → stdout with upstream image refs rewritten to local registry
  sed \
    -e "s|quay.io/cephcsi/cephcsi:v3.18.1|${REG}/${CEPHCSI_IMAGE}|g" \
    -e "s|registry.k8s.io/sig-storage/csi-provisioner:v6.3.0|${REG}/${CSI_PROVISIONER_IMAGE}|g" \
    -e "s|registry.k8s.io/sig-storage/csi-attacher:v4.13.0|${REG}/${CSI_ATTACHER_IMAGE}|g" \
    -e "s|registry.k8s.io/sig-storage/csi-resizer:v2.2.1|${REG}/${CSI_RESIZER_IMAGE}|g" \
    -e "s|registry.k8s.io/sig-storage/csi-snapshotter:v8.6.0|${REG}/${CSI_SNAPSHOTTER_IMAGE}|g" \
    -e "s|registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.18.0|${REG}/${CSI_REGISTRAR_IMAGE}|g"
}

set_ns() {
  # Replace "# replace with non-default namespace name\n  namespace: default" and bare "namespace: default"
  sed -e "s/^  namespace: default$/  namespace: ${NS}/" \
      -e "s/^    namespace: default$/    namespace: ${NS}/"
}

log "namespace $NS (apply creates it)"

# --- ConfigMaps ---
cat > "$OUT/01-ceph-config.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-config
  namespace: ${NS}
data:
  ceph.conf: |
    [global]
    auth_cluster_required = cephx
    auth_service_required = cephx
    auth_client_required = cephx
  keyring: |
YAML

# monitors: VIP placeholder (comma-separated host:port OK)
# Build JSON array of monitor strings
IFS=',' read -r -a _mons <<< "$CEPH_MON_VIP"
_json_mons=""
for m in "${_mons[@]}"; do
  m=$(echo "$m" | tr -d ' ')
  [ -n "$m" ] || continue
  if [ -n "$_json_mons" ]; then _json_mons+=", "; fi
  _json_mons+="\"${m}\""
done
[ -n "$_json_mons" ] || die "CEPH_MON_VIP empty"

cat > "$OUT/02-ceph-csi-config.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-csi-config
  namespace: ${NS}
data:
  config.json: |-
    [
      {
        "clusterID": "${CLUSTER_ID}",
        "monitors": [${_json_mons}]
      }
    ]
YAML

cat > "$OUT/03-ceph-csi-encryption-kms-config.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-csi-encryption-kms-config
  namespace: ${NS}
data:
  config.json: "{}"
YAML

# --- Secret (no encryption passphrase by default) ---
cat > "$OUT/04-csi-rbd-secret.yaml" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: csi-rbd-secret
  namespace: ${NS}
type: Opaque
stringData:
  userID: "${CSI_USER_ID}"
  userKey: "${USER_KEY}"
YAML
chmod 600 "$OUT/04-csi-rbd-secret.yaml"

# --- CSIDriver + RBAC (namespace-scoped SAs) ---
rewrite_images < "$VENDOR/csidriver.yaml" | set_ns > "$OUT/05-csidriver.yaml"

# RBAC: change ServiceAccount namespaces; ClusterRoles stay cluster-scoped
set_ns < "$VENDOR/csi-provisioner-rbac.yaml" > "$OUT/06-csi-provisioner-rbac.yaml"
set_ns < "$VENDOR/csi-nodeplugin-rbac.yaml"  > "$OUT/07-csi-nodeplugin-rbac.yaml"

# --- Provisioner: rewrite images, ns, replicas, drop hard anti-affinity on single node ---
rewrite_images < "$VENDOR/csi-rbdplugin-provisioner.yaml" | set_ns | \
  sed -e "s/^  replicas: 3$/  replicas: ${PROVISIONER_REPLICAS}/" \
  > "$OUT/08-csi-rbdplugin-provisioner.yaml.tmp"

if [ "${PROVISIONER_REPLICAS}" = "1" ]; then
  python3 "$HERE/strip-affinity.py" \
    "$OUT/08-csi-rbdplugin-provisioner.yaml.tmp" \
    "$OUT/08-csi-rbdplugin-provisioner.yaml"
  rm -f "$OUT/08-csi-rbdplugin-provisioner.yaml.tmp"
else
  mv "$OUT/08-csi-rbdplugin-provisioner.yaml.tmp" "$OUT/08-csi-rbdplugin-provisioner.yaml"
fi

rewrite_images < "$VENDOR/csi-rbdplugin.yaml" | set_ns > "$OUT/09-csi-rbdplugin.yaml"

# --- StorageClass ---
mounter_line=""
if [ -n "${RBD_MOUNTER:-}" ]; then
  mounter_line="  mounter: ${RBD_MOUNTER}"$'\n'
fi
cat > "$OUT/10-storageclass.yaml" <<YAML
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS_NAME}
provisioner: rbd.csi.ceph.com
parameters:
  clusterID: ${CLUSTER_ID}
  pool: ${RBD_POOL}
  imageFeatures: layering
${mounter_line}  csi.storage.k8s.io/provisioner-secret-name: csi-rbd-secret
  csi.storage.k8s.io/provisioner-secret-namespace: ${NS}
  csi.storage.k8s.io/controller-expand-secret-name: csi-rbd-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: ${NS}
  csi.storage.k8s.io/controller-publish-secret-name: csi-rbd-secret
  csi.storage.k8s.io/controller-publish-secret-namespace: ${NS}
  csi.storage.k8s.io/node-stage-secret-name: csi-rbd-secret
  csi.storage.k8s.io/node-stage-secret-namespace: ${NS}
  csi.storage.k8s.io/fstype: ${SC_FSTYPE}
reclaimPolicy: ${SC_RECLAIM_POLICY}
allowVolumeExpansion: ${SC_ALLOW_EXPANSION}
mountOptions:
  - discard
YAML

# --- optional smoke PVC+Pod (apply via smoke-rbd.sh; uses local registry pause) ---
cat > "$OUT/90-smoke-pvc-pod.yaml" <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rbd-smoke-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${STORAGE_CLASS_NAME}
---
apiVersion: v1
kind: Pod
metadata:
  name: rbd-smoke-pod
  namespace: default
spec:
  containers:
    - name: pause
      image: ${REGISTRY}/${PAUSE_IMAGE}
      imagePullPolicy: IfNotPresent
      volumeMounts:
        - name: rbd
          mountPath: /mnt/rbd
  volumes:
    - name: rbd
      persistentVolumeClaim:
        claimName: rbd-smoke-pvc
YAML
rm -f "$OUT/90-smoke-pvc.yaml" 2>/dev/null || true

log "rendered manifests in $OUT"
if [ "$RENDER_ONLY" = "1" ]; then
  log "RENDER_ONLY=1 — skip kubectl apply"
  ls -la "$OUT"
  exit 0
fi

log "applying (skip smoke pvc by default)"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$OUT/01-ceph-config.yaml"
kubectl apply -f "$OUT/02-ceph-csi-config.yaml"
kubectl apply -f "$OUT/03-ceph-csi-encryption-kms-config.yaml"
kubectl apply -f "$OUT/04-csi-rbd-secret.yaml"
kubectl apply -f "$OUT/05-csidriver.yaml"
kubectl apply -f "$OUT/06-csi-provisioner-rbac.yaml"
kubectl apply -f "$OUT/07-csi-nodeplugin-rbac.yaml"
kubectl apply -f "$OUT/08-csi-rbdplugin-provisioner.yaml"
kubectl apply -f "$OUT/09-csi-rbdplugin.yaml"
kubectl apply -f "$OUT/10-storageclass.yaml"

log "wait for CSI pods in $NS"
kubectl -n "$NS" rollout status deploy/csi-rbdplugin-provisioner --timeout=180s || warn "provisioner not ready yet"
kubectl -n "$NS" get pods -o wide
kubectl get sc "$STORAGE_CLASS_NAME"
log "done. Smoke: sudo ./smoke-rbd.sh   # applies $OUT/90-smoke-pvc-pod.yaml"
