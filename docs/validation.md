# Validation

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
