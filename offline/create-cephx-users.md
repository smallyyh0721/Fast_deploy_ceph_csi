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
# 内核 rbd（Ubuntu 24.04 内核 6.8）只能装 16 字节 aes key。
# Tentacle 20.2.4 默认 aes256k（32 字节）会在 dmesg 里报 libceph: secret too big 32。
# 用户已存在且是 aes256k 时要 rotate，get-or-create 不会改已有 key 的类型。
sudo cephadm shell -- ceph mon set auth_allowed_ciphers aes,aes256k
sudo cephadm shell -- ceph auth get-or-create --key-type=aes client.csi-rbd \
  mon 'profile rbd' \
  mgr 'allow rw' \
  osd 'profile rbd pool=kubernetes'
# 若上面报 insecure key type not allowed：
#   sudo cephadm shell -- ceph config set mon mon_auth_allow_insecure_key true
# 若用户已存在且类型不是 aes：
#   sudo cephadm shell -- ceph auth rotate --key-type=aes client.csi-rbd

sudo mkdir -p ./secrets
sudo cephadm shell -- ceph auth get-key client.csi-rbd | sudo tee ./secrets/csi-rbd.key >/dev/null
sudo chmod 600 ./secrets/csi-rbd.key
# 完整 keyring（可选，供备份；同样走 stdout 到宿主机）
sudo cephadm shell -- ceph auth get client.csi-rbd | sudo tee ./secrets/client.csi-rbd.keyring >/dev/null
sudo chmod 600 ./secrets/client.csi-rbd.keyring
# 把 ./secrets/csi-rbd.key 拷到 K8s 节点，设 CSI_USER_KEY_FILE（一行，无引号）
```

`CEPH_MON_VIP` 写 **VIP:端口**（ingress 占位例 `10.250.0.10:6789`），不要写单个 MON IP。
