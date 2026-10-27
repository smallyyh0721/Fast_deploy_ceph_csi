# Progress

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
