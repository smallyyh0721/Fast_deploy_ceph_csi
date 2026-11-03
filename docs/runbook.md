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
| CSI 用户 | `client.csi-rbd` → Secret `userID=csi-rbd`，key 类型 **`aes`**（16 字节） |
| RBD 映射 | **内核 rbd**（StorageClass `mounter: rbd`，宿主机 `/dev/rbdN`）。不要 `rbd-nbd` |

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
# 脚本把 key/keyring 写到宿主机 OUT_DIR（默认 ./secrets）；不要对 cephadm shell 用 -o /tmp
# 用户已存在时可再跑一遍：key 已是 aes 则只刷新 caps；是 aes256k 则 rotate 成 aes 并重写 secrets
# Tentacle 20.2.4 默认 aes256k（32 字节）。Ubuntu 24.04 内核 6.8 的 krbd 会报
# libceph: secret too big 32。CSI 客户端固定用 aes。daemon key 不动。
# 该客户端出现 AUTH_INSECURE_CLIENT_KEY_TYPE 是预期。节点全是 Linux >= 7.0 才设 CSI_KEY_TYPE=aes256k。
```

手工命令见 `offline/create-cephx-users.md`（`get-or-create` 不带 `-o`，再用 `auth get-key` / `auth get` 重定向到宿主机）。

确认 VIP 可达：`nc -vz 10.250.0.10 6789`（或 3300）。

## 3. K8s 侧：装镜像

```bash
# registry 已由 Fast_deploy_k8s 拉起
# 默认读 cluster.conf 的 NODE_IP:REGISTRY_PORT
sudo ./load-images.sh
# 现场 registry 与 example 不一致时，CLI 优先（不必改 conf）：
# sudo ./load-images.sh 192.168.180.16:5000
# sudo ./load-images.sh --registry 192.168.180.16:5000
# 或: export REGISTRY=192.168.180.16:5000 && sudo -E ./load-images.sh
```

## 4. 部署 RBD CSI

```bash
# cluster.conf 已填 CLUSTER_ID、CEPH_MON_VIP、CSI_USER_KEY_FILE
# RBD_MOUNTER=rbd（内核）。写成 rbd-nbd 脚本直接失败。
# 与 load-images 使用同一 REGISTRY（同样支持 CLI / 环境变量）
sudo ./apply-rbd-csi.sh
# sudo ./apply-rbd-csi.sh --registry 192.168.180.16:5000
# 脚本会 modprobe rbd，并检查 StorageClass mounter=rbd
kubectl -n ceph-csi get pods -o wide
kubectl get sc csi-rbd-sc -o jsonpath='{.parameters.mounter}{"\n"}'
```

单节点：`PROVISIONER_REPLICAS=1`（默认），脚本会去掉硬反亲和。

节点插件 DaemonSet 已是 privileged，并挂载宿主机 `/dev`、`/sys`、`/lib/modules`。ceph-csi 在 `/sys/bus/rbd` 不存在时会自己 `modprobe rbd`。每个 kubelet 节点需要与 `uname -r` 匹配的 `rbd` 模块（Ubuntu 一般在 `linux-modules` 里）。不要再加载 `nbd` 来当映射器。

## 5. PVC 冒烟（可选）

先完成 §4 `apply-rbd-csi.sh`（会生成 `manifests/generated/90-smoke-pvc-pod.yaml`：PVC + pause Pod）。  
冒烟镜像为本地 registry 的 `pause:3.10.1`（与 Fast_deploy_k8s / kubeadm 1.35.7 一致，`imagePullPolicy: IfNotPresent`）。只挂载不写盘。

以前用 `rbd-nbd` 建出来的 PVC **不会**跟着 StorageClass 改映射方式。重测前删掉旧冒烟对象：

```bash
kubectl delete pod rbd-smoke-pod --wait=true
kubectl delete pvc rbd-smoke-pvc --wait=true
```

```bash
# 一条命令：检查 pause → apply PVC+Pod → 等待 PVC Bound → 等待 Pod Ready
sudo ./smoke-rbd.sh
# 或: sudo ./smoke-rbd.sh --registry 192.168.180.16:5000
# Pod 等待超时：--pod-timeout > 环境变量 SMOKE_POD_TIMEOUT > cluster.conf > 默认 180s
# 格式 ^[0-9]+[smh]?$（纯数字按秒）；空值、0 或非法值直接报错退出
# sudo ./smoke-rbd.sh --pod-timeout 300s   # 或 SMOKE_POD_TIMEOUT=5m sudo -E ./smoke-rbd.sh
# 帮助: ./smoke-rbd.sh --help
```

> 升级提示：旧 `cluster.conf.example` 复制出的 conf 里是硬编码 `SMOKE_POD_TIMEOUT=180s`，会覆盖环境变量。请改成 `SMOKE_POD_TIMEOUT="${SMOKE_POD_TIMEOUT-180s}"`。另外普通 `sudo` 会丢掉环境变量，用 `sudo -E` 或直接传 `--pod-timeout`。

pause 检查（现场自检）：

```bash
curl -s http://$NODE_IP:5000/v2/_catalog
curl -s http://$NODE_IP:5000/v2/pause/tags/list
ctr -n k8s.io images ls | grep pause
```

若 catalog 无 pause：先跑 Fast_deploy_k8s 的 `setup-registry.sh`，或使用含 `pause-3.10.1.tar` 的新 CSI 离线包后再 `sudo ./load-images.sh`。

脚本先等 PVC Bound，再 `kubectl wait --for=condition=Ready pod/rbd-smoke-pod`；Pod 超时未 Ready 会打印 describe 与 events 并非 0 退出。

合格：脚本退出码 0；PVC `rbd-smoke-pvc` Bound；Pod `rbd-smoke-pod` Running；PV `volumeAttributes.mounter` 为 `rbd`；本节点 `/proc/mounts` 里该 PV 的源设备是 `/dev/rbd*`（不是 `/dev/nbd*`）；`kubectl -n ceph-csi logs` 无持续报错。

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
