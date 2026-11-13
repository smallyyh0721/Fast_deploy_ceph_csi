# Fast_deploy_ceph_csi

Offline (air-gapped) **Ceph CSI RBD-only** toolkit for Kubernetes.

**Depends on (not included):**
- [`Fast_deploy_k8s`](https://github.com/smallyyh0721/Fast_deploy_k8s) — K8s Ready + local registry `NODE_IP:5000`
- [`Fast_deploy_ceph`](https://github.com/smallyyh0721/Fast_deploy_ceph) — Ceph Tentacle 20.2.4 with **cephadm ingress VIP** for monitors

This repo is **CSI only**. It does **not** bundle K8s or Ceph daemons. CephFS CSI is out of scope (use hostPath later if needed).

| Pin | Value |
|---|---|
| Kubernetes | **1.35.7** (compatible 1.34–1.36) |
| Ceph | Tentacle **20.2.4** |
| ceph-csi | **v3.18.1** (`quay.io/cephcsi/cephcsi`) |
| Sidecars | provisioner v6.3.0 · attacher v4.13.0 · resizer v2.2.1 · snapshotter v8.6.0 · node-driver-registrar v2.18.0 |

**CephX** = keyrings / K8s Secrets — **no images**.

## Layout

- `build/build-bundle.sh` — internet machine: pull images → tar + `SHA256SUMS`
- `offline/` — air-gapped K8s node:
  1. `cluster.conf` (from example)
  2. `load-images.sh` — import + push to local registry (`HOST:PORT` / `--registry` / `REGISTRY` env override conf)
  3. Ceph side: `create-cephx-users.sh` (on Ceph admin)
  4. `apply-rbd-csi.sh` — render manifests (VIP + secrets) and apply (same registry override)
  5. `smoke-rbd.sh` — apply `90-smoke-pvc-pod.yaml` (PVC+pause Pod), wait for PVC Bound, then Pod Ready (`--pod-timeout` > env/conf `SMOKE_POD_TIMEOUT` > 180s; format `^[0-9]+[smh]?$`, empty/zero/invalid is an error); non-zero exit if the pod never becomes Ready. Plain `sudo` drops env vars: use `SMOKE_POD_TIMEOUT=5m sudo -E ./smoke-rbd.sh` or `--pod-timeout`. Confs copied from the old example have hardcoded `SMOKE_POD_TIMEOUT=180s` (overrides env) — change it to `SMOKE_POD_TIMEOUT="${SMOKE_POD_TIMEOUT-180s}"`. Precedence: CLI > env vars > `cluster.conf` (conf uses `${VAR-default}`, e.g. `SMOKE_POD_TIMEOUT="${SMOKE_POD_TIMEOUT-180s}"`, so env wins) > default. `--help` for usage
- `docs/runbook.md` — **现场操作手册**

## RBD mounter

Volumes map with **kernel rbd** (`mounter: rbd`, host device `/dev/rbdN`). `rbd-nbd` is refused.

Ceph Tentacle 20.2.4 creates `aes256k` keys (32 bytes) by default. Ubuntu 24.04 kernel 6.8 rejects those on krbd (`libceph: secret too big 32`), which is why an earlier bundle used NBD. `create-cephx-users.sh` creates or rotates only `client.<CSI_USER_ID>` to a 16-byte `aes` key. Daemon keys stay on the cluster default. `AUTH_INSECURE_CLIENT_KEY_TYPE` for that one client is expected until kubelet nodes run Linux 7.0 or newer (`CSI_KEY_TYPE=aes256k`). The node plugin is already privileged and bind-mounts `/dev`, `/sys`, and `/lib/modules`; it modprobes `rbd`. `apply-rbd-csi.sh` also runs `modprobe rbd` on the node where it is executed.

Live check on 2026-11-03: `fast-k8s-deploy` (`10.11.128.44`) mounted the smoke volume from `/dev/rbd0`. Record: `docs/validation.md`.

An existing PV keeps the mounter it was provisioned with. Delete `rbd-smoke-pod` and `rbd-smoke-pvc` before re-running smoke after switching off NBD.

## Field order

1. K8s Ready (`Fast_deploy_k8s`)
2. Ceph healthy + **VIP** monitors (`Fast_deploy_ceph` ingress)
3. Create RBD pool + CephX user with key type `aes` (on Ceph)
4. Load CSI images → apply RBD CSI (kernel rbd) → `./smoke-rbd.sh` (PVC+pause)

## Release

- [bundle-rbd-csi-v3.18.1-20261110](https://github.com/smallyyh0721/Fast_deploy_ceph_csi/releases/tag/bundle-rbd-csi-v3.18.1-20261110) — `ceph-csi-rbd-v3.18.1-20261110-offline-bundle.tar` (kernel rbd, `mounter: rbd`, 16-byte `aes` CSI key; built from main `443687d`)
- [bundle-rbd-csi-v3.18.1-20261026](https://github.com/smallyyh0721/Fast_deploy_ceph_csi/releases/tag/bundle-rbd-csi-v3.18.1-20261026) — `ceph-csi-rbd-v3.18.1-20261026-offline-bundle.tar` (smoke-rbd waits Pod Ready; #2/#3/#4/#5)
- [bundle-rbd-csi-v3.18.1](https://github.com/smallyyh0721/Fast_deploy_ceph_csi/releases/tag/bundle-rbd-csi-v3.18.1) — `ceph-csi-rbd-v3.18.1-offline-bundle.tar` (kept)
