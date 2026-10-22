# Ceph CSI RBD 离线对接现场手册

> **范围**：仅 **RBD CSI**。不装 CephFS CSI。  
> **依赖**：[`Fast_deploy_k8s`](https://github.com/smallyyh0721/Fast_deploy_k8s)（Node Ready + `NODE_IP:5000` registry）+ [`Fast_deploy_ceph`](https://github.com/smallyyh0721/Fast_deploy_ceph)（Ceph 20.2.4 + **cephadm ingress VIP**）。  
> **版本**：ceph-csi **v3.18.1** · K8s **1.35.x** · Ceph Tentacle **20.2.4**。  
> **CephX**：keyring / Secret，**无镜像**。

## 0. 参数

| 项 | 占位 / 示例 |
|---|---|
| K8s registry | `10.250.0.11:5000`（与 Fast_deploy_k8s 一致） |
| Ceph MON VIP | `CEPH_MON_VIP=10.250.0.10:6789`（ingress；可用 `:3300`） |
| CLUSTER_ID | `ceph fsid` 输出 |
| RBD pool | `kubernetes` |
| CSI 用户 | `client.csi-rbd` → Secret `userID=csi-rbd` |

```text
顺序：K8s Ready → Ceph+VIP → 建 pool/CephX → load CSI 镜像 → apply → PVC 冒烟
```

## 1. 解包

```bash
sudo mkdir -p /opt/ceph-csi-offline
sudo tar -xf ceph-csi-rbd-v3.18.1-offline-bundle.tar -C /opt/ceph-csi-offline
cd /opt/ceph-csi-offline/offline
sudo cp cluster.conf.example cluster.conf
# 编辑：NODE_IP、CEPH_MON_VIP、CLUSTER_ID、RBD_POOL、CSI_USER_KEY_FILE
```

## 2. Ceph 侧（admin 节点）

```bash
# 把本目录 create-cephx-users.sh 拷到 Ceph node1，或在本机有 cephadm 时：
sudo ./create-cephx-users.sh
# 记录 FSID → CLUSTER_ID；把 secrets/csi-rbd.key 拷到 K8s 节点
```

确认 VIP 可达：`nc -vz 10.250.0.10 6789`（或 3300）。

## 3. K8s 侧：装镜像

```bash
# registry 已由 Fast_deploy_k8s 拉起
sudo ./load-images.sh
```

## 4. 部署 RBD CSI

```bash
# cluster.conf 已填 CLUSTER_ID、CEPH_MON_VIP、CSI_USER_KEY_FILE
sudo ./apply-rbd-csi.sh
kubectl -n ceph-csi get pods -o wide
kubectl get sc csi-rbd-sc
```

单节点：`PROVISIONER_REPLICAS=1`（默认），脚本会去掉硬反亲和。

## 5. PVC 冒烟（可选）

`apply-rbd-csi.sh` 生成 `manifests/generated/90-smoke-pvc-pod.yaml`。  
默认容器镜像指向本机 registry 的 `pause`（只挂载不写盘）。要写盘请换成节点上已有的镜像，例如：

```bash
kubectl apply -f manifests/generated/90-smoke-pvc-pod.yaml
kubectl get pvc rbd-smoke-pvc
kubectl describe pvc rbd-smoke-pvc
```

合格：PVC Bound；Pod Running；`kubectl -n ceph-csi logs` 无持续报错。

## 6. 兼容矩阵（钉死）

| 组件 | 镜像 |
|---|---|
| cephcsi | `quay.io/cephcsi/cephcsi:v3.18.1` |
| provisioner | `registry.k8s.io/sig-storage/csi-provisioner:v6.3.0` |
| attacher | `registry.k8s.io/sig-storage/csi-attacher:v4.13.0` |
| resizer | `registry.k8s.io/sig-storage/csi-resizer:v2.2.1` |
| snapshotter | `registry.k8s.io/sig-storage/csi-snapshotter:v8.6.0` |
| registrar | `registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.18.0` |

上游声明 v3.18.1 测过 K8s **1.34 / 1.35 / 1.36**；RBD 需 Ceph ≥ Pacific（Tentacle 20.2.4 OK）。
