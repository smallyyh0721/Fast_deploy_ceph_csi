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

# 不要对 cephadm shell 使用 -o /tmp/...（写在容器内，宿主机 cp 会失败）
sudo cephadm shell -- ceph auth get-or-create client.csi-rbd \
  mon 'profile rbd' \
  mgr 'allow rw' \
  osd 'profile rbd pool=kubernetes'

sudo mkdir -p ./secrets
sudo cephadm shell -- ceph auth get-key client.csi-rbd | sudo tee ./secrets/csi-rbd.key >/dev/null
sudo chmod 600 ./secrets/csi-rbd.key
# 完整 keyring（可选，供备份；同样走 stdout 到宿主机）
sudo cephadm shell -- ceph auth get client.csi-rbd | sudo tee ./secrets/client.csi-rbd.keyring >/dev/null
sudo chmod 600 ./secrets/client.csi-rbd.keyring
# 把 ./secrets/csi-rbd.key 拷到 K8s 节点，设 CSI_USER_KEY_FILE（一行，无引号）
```

`CEPH_MON_VIP` 写 **VIP:端口**（ingress 占位例 `10.250.0.10:6789`），不要写单个 MON IP。
