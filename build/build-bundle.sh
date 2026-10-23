#!/usr/bin/env bash
# Run on an INTERNET-connected x86_64 machine with podman + curl.
# Produces: $OUT/{images,vendor,offline,docs} + SHA256SUMS + optional tarball
set -euo pipefail
CSI_VERSION=${CSI_VERSION:-v3.18.1}
ARCH=${ARCH:-amd64}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
OUT=${OUT:-$REPO/../Fast_deploy_ceph_csi-bundle}
MAKE_TAR=${MAKE_TAR:-1}
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO=sudo

mkdir -p "$OUT/images"

echo "== image list"
cp -f "$HERE/images.list" "$OUT/images/images.list"
mapfile -t IMGS < <(grep -vE '^\s*(#|$)' "$HERE/images.list")

echo "== pull + save"
for img in "${IMGS[@]}"; do
  echo "  pull $img"
  $SUDO podman pull --arch "$ARCH" "$img"
done

save_one() {
  local img="$1" out="$2"
  if [ -s "$out" ]; then
    echo "  skip existing $(basename "$out")"
    return
  fi
  echo "  save $img -> $(basename "$out")"
  $SUDO podman save --format docker-archive -o "$out" "$img"
  $SUDO chown "$(id -u):$(id -g)" "$out" 2>/dev/null || true
}

save_one "quay.io/cephcsi/cephcsi:v3.18.1"                         "$OUT/images/cephcsi-v3.18.1.tar"
save_one "registry.k8s.io/sig-storage/csi-provisioner:v6.3.0"       "$OUT/images/csi-provisioner-v6.3.0.tar"
save_one "registry.k8s.io/sig-storage/csi-attacher:v4.13.0"         "$OUT/images/csi-attacher-v4.13.0.tar"
save_one "registry.k8s.io/sig-storage/csi-resizer:v2.2.1"           "$OUT/images/csi-resizer-v2.2.1.tar"
save_one "registry.k8s.io/sig-storage/csi-snapshotter:v8.6.0"       "$OUT/images/csi-snapshotter-v8.6.0.tar"
save_one "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.18.0" "$OUT/images/csi-node-driver-registrar-v2.18.0.tar"
save_one "registry.k8s.io/pause:3.10.1"                                   "$OUT/images/pause-3.10.1.tar"

cat > "$OUT/images/TAGS.env" <<TAGS
CSI_VERSION=v3.18.1
CEPHCSI_IMAGE=cephcsi/cephcsi:v3.18.1
CSI_PROVISIONER_IMAGE=sig-storage/csi-provisioner:v6.3.0
CSI_ATTACHER_IMAGE=sig-storage/csi-attacher:v4.13.0
CSI_RESIZER_IMAGE=sig-storage/csi-resizer:v2.2.1
CSI_SNAPSHOTTER_IMAGE=sig-storage/csi-snapshotter:v8.6.0
CSI_REGISTRAR_IMAGE=sig-storage/csi-node-driver-registrar:v2.18.0
PAUSE_TAG=3.10.1
PAUSE_IMAGE=pause:3.10.1
TAGS

echo "== copy offline scripts + vendor + docs"
rm -rf "$OUT/offline" "$OUT/vendor" "$OUT/docs" "$OUT/build"
mkdir -p "$OUT/offline" "$OUT/vendor" "$OUT/docs" "$OUT/build"
cp -a "$REPO/offline/." "$OUT/offline/"
cp -a "$REPO/vendor/." "$OUT/vendor/"
cp -a "$REPO/docs/." "$OUT/docs/" 2>/dev/null || mkdir -p "$OUT/docs"
cp -a "$REPO/build/images.list" "$OUT/build/"
cp -a "$REPO/README.md" "$OUT/"
# ensure generated dir exists empty
mkdir -p "$OUT/offline/manifests/generated"
rm -f "$OUT/offline/cluster.conf" 2>/dev/null || true

echo "== SHA256SUMS"
(
  cd "$OUT"
  find images offline vendor docs README.md build -type f 2>/dev/null | sort | xargs sha256sum
) > "$OUT/SHA256SUMS"

BUNDLE_NAME="ceph-csi-rbd-${CSI_VERSION}-offline"
TAR_PATH="/workspace/${BUNDLE_NAME}-bundle.tar"
if [ "$MAKE_TAR" = "1" ]; then
  echo "== tar $TAR_PATH"
  rm -f "$TAR_PATH" "${TAR_PATH}.sha256"
  tar -C "$OUT" -cf "$TAR_PATH" \
    images offline vendor docs build README.md SHA256SUMS
  sha256sum "$TAR_PATH" | tee "${TAR_PATH}.sha256"
  ls -lh "$TAR_PATH"
fi

echo "== done OUT=$OUT"
du -sh "$OUT" "$OUT/images"/* 2>/dev/null | head -20
