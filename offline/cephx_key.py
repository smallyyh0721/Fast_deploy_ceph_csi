#!/usr/bin/env python3
"""Classify CephX keys for kernel rbd.

Ceph CryptoKey::encode (src/auth/Crypto.cc) is little-endian:
  u16 type, u32 created.sec, u32 created.nsec, u16 secret_len, secret bytes.

type 1 (aes) is a 16-byte secret. type 2 (aes256k) is 32 bytes.
Ubuntu 24.04 kernel 6.8 libceph accepts 16 and rejects 32
("libceph: secret too big 32").
"""
import base64
import json
import struct
import sys

# include/linux/ceph/ceph_fs.h (and Ceph userspace CEPH_CRYPTO_*).
TYPE_NAMES = {0: "none", 1: "aes", 2: "aes256k"}


def load_json(text):
    text = text.strip()
    start = None
    for i, ch in enumerate(text):
        if ch in "{[":
            start = i
            break
    if start is None:
        raise SystemExit("no JSON in ceph output")
    return json.loads(text[start:])


def decode_key(key):
    raw = base64.b64decode(key.strip(), validate=True)
    header = struct.calcsize("<HIIH")
    if len(raw) < header:
        raise SystemExit(f"key blob too short ({len(raw)} bytes)")
    typ, _sec, _nsec, slen = struct.unpack_from("<HIIH", raw, 0)
    if header + slen != len(raw):
        raise SystemExit(
            f"key blob length {len(raw)} != header {header} + secret {slen}"
        )
    name = TYPE_NAMES.get(typ)
    if name is None:
        raise SystemExit(f"unknown CephX key type {typ}")
    return name, slen


def cipher_names(doc):
    if isinstance(doc, dict) and "auth_allowed_ciphers" not in doc:
        return None
    ciphers = doc.get("auth_allowed_ciphers") or []
    names = []
    for item in ciphers:
        if isinstance(item, str):
            name = item
        elif isinstance(item, dict):
            name = item.get("name") or item.get("type_str") or item.get("cipher") or ""
        else:
            name = ""
        if name:
            names.append(name)
    return names


def entity_type(doc, entity):
    data = doc.get("data", doc) if isinstance(doc, dict) else {}
    secrets = data.get("secrets") or []
    for item in secrets:
        ent = item.get("entity") or {}
        name = f"{ent.get('type_str', '')}.{ent.get('id', '')}"
        if name != entity:
            continue
        key = (item.get("auth") or {}).get("key") or {}
        return key.get("type_str") or ""
    return ""


def selftest():
    aes = base64.b64encode(
        struct.pack("<HIIH", 1, 123, 456, 16) + b"1234567890123456"
    ).decode()
    aes256 = base64.b64encode(
        struct.pack("<HIIH", 2, 1, 2, 32) + (b"K" * 32)
    ).decode()
    assert decode_key(aes) == ("aes", 16), decode_key(aes)
    assert decode_key(aes256) == ("aes256k", 32), decode_key(aes256)
    dump = {
        "auth_allowed_ciphers": [{"name": "aes256k"}, {"type_str": "aes"}],
    }
    assert cipher_names(dump) == ["aes256k", "aes"]
    assert cipher_names({"fsid": "x"}) is None
    keys = {
        "data": {
            "secrets": [
                {
                    "entity": {"type_str": "client", "id": "csi-rbd"},
                    "auth": {"key": {"type_str": "aes256k"}},
                }
            ]
        }
    }
    assert entity_type(keys, "client.csi-rbd") == "aes256k"
    assert entity_type(keys, "client.other") == ""
    print("ok")


def main(argv):
    if len(argv) < 2:
        raise SystemExit("usage: cephx_key.py selftest|ciphers|entity NAME|decode KEY")
    cmd = argv[1]
    if cmd == "selftest":
        selftest()
        return
    if cmd == "ciphers":
        names = cipher_names(load_json(sys.stdin.read()))
        if names is None:
            print("MISSING")
        else:
            print(",".join(names))
        return
    if cmd == "entity":
        if len(argv) != 3:
            raise SystemExit("usage: cephx_key.py entity client.csi-rbd")
        print(entity_type(load_json(sys.stdin.read()), argv[2]))
        return
    if cmd == "decode":
        if len(argv) != 3:
            raise SystemExit("usage: cephx_key.py decode BASE64KEY")
        name, slen = decode_key(argv[2])
        print(f"{name} {slen}")
        return
    raise SystemExit(f"unknown command {cmd}")


if __name__ == "__main__":
    main(sys.argv)
