# Progress

- 2026-10-22: Repo scaffold; pin ceph-csi **v3.18.1** + sidecars; RBD-only; separate from Fast_deploy_k8s.
- Bundle build OK: `ceph-csi-rbd-v3.18.1-offline-bundle.tar` (~954 MiB).
- Manifest render dry-run OK (`RENDER_ONLY=1`): VIP monitors, local registry image rewrite, replicas=1 affinity strip.
- Release: `bundle-rbd-csi-v3.18.1`.
- Full PVC smoke on air-gapped K8s+Ceph+VIP: **not run** (residual risk — needs live cluster).
