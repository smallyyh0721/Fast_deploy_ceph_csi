# CephX for RBD CSI（在 Ceph 管理节点执行）

CephX **不是镜像**，只要 keyring / K8s Secret。

推荐直接跑脚本（同目录）：

```bash
# 在 Ceph admin（node1）上，可先 cp cluster.conf 填 RBD_POOL / CSI_USER_ID
sudo ./create-cephx-users.sh
```

或手工：

```bash
sudo cephadm shell -- ceph fsid          # → CLUSTER_ID
sudo cephadm shell -- ceph osd pool create kubernetes 32
sudo cephadm shell -- ceph osd pool application enable kubernetes rbd
sudo cephadm shell -- ceph rbd pool init kubernetes

sudo cephadm shell -- ceph auth get-or-create client.csi-rbd \
  mon 'profile rbd' \
  mgr 'allow rw' \
  osd 'profile rbd pool=kubernetes' \
  -o /tmp/client.csi-rbd.keyring

sudo cephadm shell -- ceph auth get-key client.csi-rbd
# 把输出的 key 写到 K8s 节点 CSI_USER_KEY_FILE（一行，无引号）
```

`CEPH_MON_VIP` 写 **VIP:端口**（ingress 占位例 `10.250.0.10:6789`），不要写单个 MON IP。
