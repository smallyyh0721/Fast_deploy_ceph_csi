# Validation

## Live cluster: bundle-rbd-csi-v3.18.1-20261026 (2026-10-26) — SUCCESS

Release tarball `ceph-csi-rbd-v3.18.1-20261026-offline-bundle.tar`, 1000427520 bytes, sha256 `1da7f5fd2eca93a118bdb5300630591309b87b4337f6c6c82c2f71ef95d90ef0`. Scripts were the packaged `offline/`. No script edits during the test.

K8s node `k8s-43` at `10.11.4.43`, Ubuntu 24.04.5, kernel 6.8.0-142-generic, single-node v1.35.7 from `Fast_deploy_k8s` release `bundle-1.35.7`. The local registry listens on `10.11.4.43:5000`.

Ceph fsid `16c96e91-d119-11f1-9c37-021104000028`. Monitors `10.11.4.40:6789,10.11.4.41:6789,10.11.4.42:6789`. This cluster has no monitor VIP. `10.11.4.50` is the RGW VIP and was not used as a monitor. Pool `kubernetes` and user `client.csi-rbd` already existed. `cluster.conf` set `RBD_MOUNTER=rbd-nbd`, and the node loaded `nbd`. Ubuntu 24.04 kernel 6.8 rejects krbd secrets (`libceph: secret too big 32`, issue #1).

```bash
cd /opt/ceph-csi-offline/offline
sudo ./load-images.sh
sudo ./apply-rbd-csi.sh
sudo ./smoke-rbd.sh
```

- Images pushed to `10.11.4.43:5000`
- CSI provisioner 7/7 Running, node plugin 3/3 Running
- `smoke-rbd.sh` waited until the pod was Ready, then exited 0
- PVC `rbd-smoke-pvc` Bound, 1Gi, volume `pvc-50f74b3f-c92e-4105-a3e4-6621821f20b5`
- `rbd-smoke-pod` 1/1 Running
- StorageClass `csi-rbd-sc` has `mounter: rbd-nbd` and `pool: kubernetes`
- The host mount is `/dev/nbd1`
- After the run: same fsid, 12 OSDs up/in, 321 PGs active+clean
- `HEALTH_WARN` only: `mon.nettest-41` clock skew. Not a script failure
- No new script defect and no new issue

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

- The NBD result above is historical. Current scripts set StorageClass `mounter: rbd` and pin `client.csi-rbd` to a 16-byte `aes` key. Ubuntu 24.04 kernel 6.8 rejects 32-byte `aes256k` secrets (`libceph: secret too big 32`, #1). `AUTH_INSECURE_CLIENT_KEY_TYPE` for that client is expected. `CSI_KEY_TYPE=aes256k` is for Linux 7.0+ nodes only.
- Existing PVs keep the mounter stored at provision time. Delete `rbd-smoke-pod` and `rbd-smoke-pvc` before smoking a cluster that previously used `rbd-nbd`.
- `CEPH_MON_VIP` is the monitor `host:port` list. On this cluster that is the three mons, not the RGW VIP `10.11.4.50`.
- One mon clock skew stays `HEALTH_WARN` when the Ceph deploy leaves chrony unmanaged.
