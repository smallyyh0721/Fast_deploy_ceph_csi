# Validation

## Done in this toolkit build

| Check | Result |
|---|---|
| Version pin (ceph-csi v3.18.1 + sidecars from upstream deploy YAMLs) | OK |
| Bundle build (pull images, tar, SHA256) | see progress.md |
| Manifest render dry-run (`apply-rbd-csi.sh` logic / sed rewrite) | OK on build host with fake conf |
| Full PVC smoke on air-gapped K8s + Ceph+VIP | **Not run** if VMs unavailable — residual risk |

## Residual risk

- End-to-end RBD map/mount depends on kernel `rbd` module on K8s nodes, VIP reachability, and correct CephX caps.
- Single-node provisioner anti-affinity stripped only when `PROVISIONER_REPLICAS=1`.
- Smoke pod image must exist in the local registry (pause from Fast_deploy_k8s).
