# Progress

## 2026-11-03 kernel rbd live CSI — SUCCESS

- [x] Branch `cursor/kernel-rbd-mounter-3537` scripts over the 20261026 image bundle. New VMs: `fast-ceph-deploy` (`10.11.128.43`, Tentacle 20.2.4, 3 OSDs) and `fast-k8s-deploy` (`10.11.128.44`, v1.35.7)
- [x] `client.csi-rbd` key type `aes` (16 bytes). StorageClass `mounter: rbd`. Host mount `/dev/rbd0`. No `secret too big`
- [x] PVC `rbd-smoke-pvc` Bound and `rbd-smoke-pod` Running
- [!] Single-node `HEALTH_WARN`: `POOL_NO_REDUNDANCY` and the expected `AUTH_INSECURE_*` warnings for that aes client key
- [!] `create-cephx-users.sh` hid Tentacle EPERM on `osd pool set size 1`. Filed #7. Fixed on this branch in `5b21530` and `6025ebb`
- Detail: `docs/validation.md`

## Kernel rbd (krbd)

- StorageClass `mounter: rbd` (kernel, `/dev/rbdN`). `apply-rbd-csi.sh` runs `modprobe rbd` and refuses `RBD_MOUNTER=rbd-nbd`.
- `create-cephx-users.sh` pins `client.csi-rbd` to CephX key type `aes` (16-byte secret) so Ubuntu 24.04 kernel 6.8 can install it. `aes256k` (32 bytes) is what produced `libceph: secret too big 32`.
- Live pass is the 2026-11-03 section above. The 2026-10-26 section below used NBD and is historical.

## 2026-10-26 bundle-rbd-csi-v3.18.1-20261026 live CSI — SUCCESS

- [x] Release tarball deployed unmodified on `k8s-43` (v1.35.7) against existing Ceph fsid `16c96e91-d119-11f1-9c37-021104000028`
- [x] `load-images.sh`, `apply-rbd-csi.sh`, `smoke-rbd.sh` (script waited for Pod Ready)
- [x] PVC `rbd-smoke-pvc` Bound and `rbd-smoke-pod` Running; StorageClass `mounter: rbd-nbd`; host mount `/dev/nbd1`
- [!] `HEALTH_WARN` only for `mon.nettest-41` clock skew. Not a script defect
- Detail: `docs/validation.md`

- 2026-10-22: Repo scaffold; pin ceph-csi **v3.18.1** + sidecars; RBD-only; separate from Fast_deploy_k8s.
- Bundle build OK: `ceph-csi-rbd-v3.18.1-offline-bundle.tar` (~954 MiB).
- Manifest render dry-run OK (`RENDER_ONLY=1`): VIP monitors, local registry image rewrite, replicas=1 affinity strip.
- Release: `bundle-rbd-csi-v3.18.1`.
- 2026-10-22 release `bundle-rbd-csi-v3.18.1`: packaged `smoke-rbd.sh` returned before the pod was Ready (#2). The 20261026 release above is the live pass.
