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
usage() {
  cat <<'USAGE'
Usage: sudo ./apply-rbd-csi.sh [HOST:PORT | --registry HOST:PORT]
  Render RBD CSI manifests and kubectl apply (RENDER_ONLY=1: render only).
  StorageClass mounter is kernel rbd (value "rbd", device /dev/rbdN).
  RBD_MOUNTER=rbd-nbd is refused. Apply also runs modprobe rbd.
  Registry priority: CLI > env REGISTRY > cluster.conf (NODE_IP:REGISTRY_PORT).
  Plain sudo drops env vars: use sudo -E, or pass the registry on the CLI.
USAGE
}
# Help handled here (value-aware: skips the --registry value).
_a=("$@"); _i=0
while [ "$_i" -lt "${#_a[@]}" ]; do
  case "${_a[$_i]}" in
    -h|--help) usage; exit 0 ;;
    --registry) _i=$((_i + 2)); continue ;;
  esac
  _i=$((_i + 1))
done
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
# ceph-csi mounter "rbd" is kernel rbd (krbd), device /dev/rbdN.
# "krbd" is an alias we write as "rbd". Empty means the same.
# rbd-nbd is userspace NBD and is refused so an old cluster.conf cannot keep it.
case "${RBD_MOUNTER:-rbd}" in
  ""|rbd|krbd) SC_MOUNTER=rbd ;;
  rbd-nbd|nbd)
    die "RBD_MOUNTER=${RBD_MOUNTER} selects userspace NBD (/dev/nbd*).
  This deploy maps with kernel rbd. Set RBD_MOUNTER=rbd in cluster.conf
  and re-run create-cephx-users.sh so client.${CSI_USER_ID} is key type aes
  (Ubuntu 24.04 kernel 6.8 rejects 32-byte aes256k: libceph secret too big)."
    ;;
  *)
    die "unsupported RBD_MOUNTER=${RBD_MOUNTER} (want rbd or krbd)"
    ;;
esac
log "RBD mounter: ${SC_MOUNTER} (kernel rbd)"

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
  # kernel rbd. ceph-csi value "rbd" maps /dev/rbdN via the rbd module.
  mounter: ${SC_MOUNTER}
  csi.storage.k8s.io/provisioner-secret-name: csi-rbd-secret
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
# ceph-csi nodeplugin is already privileged and mounts /dev, /sys, and
# /lib/modules, and it modprobes "rbd" if /sys/bus/rbd is missing.
# Load it here too so a single-node apply fails before pods start if the
# module package is absent. Other nodes get the module from the node plugin.
log "modprobe rbd (kernel mapper)"
modprobe rbd || die "modprobe rbd failed (kernel $(uname -r)).
  Install the matching linux-modules package. Kernel rbd needs /sys/bus/rbd and /dev/rbd*.
  Do not set RBD_MOUNTER=rbd-nbd."
[ -d /sys/bus/rbd ] || die "rbd module did not create /sys/bus/rbd"
log "kernel rbd sysfs: /sys/bus/rbd"

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
got_mounter=$(kubectl get sc "$STORAGE_CLASS_NAME" -o jsonpath='{.parameters.mounter}')
[ "$got_mounter" = rbd ] || die "StorageClass ${STORAGE_CLASS_NAME} mounter is '${got_mounter}', want rbd"
log "StorageClass ${STORAGE_CLASS_NAME} mounter=rbd (kernel)"
log "done. Smoke: sudo ./smoke-rbd.sh   # applies $OUT/90-smoke-pvc-pod.yaml"
log "Existing PVs keep the mounter they were created with. Delete an old NBD smoke PVC before retesting."
