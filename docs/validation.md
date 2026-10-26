# Validation

## Live cluster 2026-10-26 — PVC Bound, pod Running after #1

Against Ceph fsid `16c96e91-d119-11f1-9c37-021104000028` (mons `10.11.4.40:6789,10.11.4.41:6789,10.11.4.42:6789`, no mon VIP). K8s node `k8s-43` at `10.11.4.43`, single-node 1.35.7.

- `create-cephx-users.sh` created pool `kubernetes` and `client.csi-rbd`.
- `load-images.sh` and `apply-rbd-csi.sh` succeeded. CSI provisioner 7/7 and node plugin 3/3 Running.
- First smoke: PVC Bound, pod mount failed. krbd / `libceph: secret too big 32`. Filed [#1](https://github.com/smallyyh0721/Fast_deploy_ceph_csi/issues/1). Fix `RBD_MOUNTER=rbd-nbd` is `99049d4`.
- After recreating the StorageClass, PVC Bound and `rbd-smoke-pod` Running with `mounter: rbd-nbd`.
- `smoke-rbd.sh` in the release returns after PVC Bound and does not fail if the pod never runs. Filed [#2](https://github.com/smallyyh0721/Fast_deploy_ceph_csi/issues/2).

| Check | Result |
|---|---|
| Version pin: ceph-csi v3.18.1 (K8s 1.34–1.36 matrix) + sidecars from upstream deploy YAMLs | OK |
| Bundle build (6 images → tar + SHA256) | OK |
| Manifest render (`RENDER_ONLY=1`): VIP in ceph-csi-config, images → `NODE_IP:5000/...`, SC + Secret templates | OK |
| `load-images.sh` / `kubectl apply` on live air-gapped K8s | Not run here |
| PVC Bound + Pod mount against Ceph VIP | **Not run** — residual risk |

## Residual risk

- Needs kernel `rbd` on K8s nodes, VIP reachability (`CEPH_MON_VIP`), correct CephX caps, and RBD pool ready.
- Smoke file is PVC-only; a mount Pod needs an image already in the local registry.
