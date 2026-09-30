#!/usr/bin/env python3
"""Minis iOS debug server client (protocol v1, stdlib only).

Usage:
    python3 minis_rpc.py [--host HOST:PORT] [--png FILE] <method> [params-json]

Examples:
    python3 minis_rpc.py rpc.discover
    python3 minis_rpc.py debug.tap '{"text": "Settings"}'
    python3 minis_rpc.py --png shot.png debug.screenshot '{"scale": 0.5}'

Pairs with `plain: true` on first use (loopback only: simulator, or a real
device forwarded over USB, e.g. `iproxy 8321 8321`). The simulator approves
automatically; a real device shows an Allow/Deny alert. The token is cached in
~/.cache/minis-debug/<host>_<port>.token and reused until the server rejects it.
"""
import base64
import hashlib
import hmac
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request

CACHE_DIR = os.path.expanduser("~/.cache/minis-debug")


def _hmac(key, data):
    return hmac.new(key, data, hashlib.sha256).digest()


def _xor_stream(key, nonce, data):
    # PRF-CTR: keystream_i = HMAC-SHA256(key, nonce || be32(i))
    out = bytearray()
    for i in range(0, len(data), 32):
        block = _hmac(key, nonce + (i // 32).to_bytes(4, "big"))
        out += bytes(a ^ b for a, b in zip(data[i:i + 32], block))
    return bytes(out)


def _post(base, path, obj, timeout):
    req = urllib.request.Request(base + path, data=json.dumps(obj).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def _token_path(host):
    return os.path.join(CACHE_DIR, host.replace(":", "_") + ".token")


def pair(base, host):
    status, body = _post(base, "/pair", {"client_name": "minis_rpc.py", "plain": True}, timeout=90)
    if status != 200:
        sys.exit(f"pair failed ({status}): {body}")
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(_token_path(host), "w") as f:
        f.write(body["token"])
    return bytes.fromhex(body["token"])


def call(base, key, method, params, timeout=660):
    tok4 = hashlib.sha256(key).digest()[:4]
    nonce = secrets.token_bytes(16)
    ts = int(time.time())
    plaintext = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    k_mac = _hmac(key, b"minis-dbg-v1|mac" + nonce)
    ct = _xor_stream(_hmac(key, b"minis-dbg-v1|enc-req" + nonce), nonce, plaintext)
    tag = _hmac(k_mac, b"v1" + tok4 + ts.to_bytes(8, "big") + nonce + ct)
    status, body = _post(base, "/rpc", {
        "v": 1, "tok": tok4.hex(), "ts": ts, "nonce": nonce.hex(),
        "ct": base64.b64encode(ct).decode(), "tag": tag.hex(),
    }, timeout)
    if status == 401:
        return None  # 令牌失效或未知：由调用方重新配对
    resp_ct = base64.b64decode(body["ct"])
    if not hmac.compare_digest(_hmac(k_mac, b"resp" + nonce + resp_ct), bytes.fromhex(body["tag"])):
        sys.exit("response MAC mismatch")
    return json.loads(_xor_stream(_hmac(key, b"minis-dbg-v1|enc-resp" + nonce), nonce, resp_ct))


def main(argv):
    host, png = "127.0.0.1:8321", None
    while argv and argv[0].startswith("--"):
        flag, value, argv = argv[0], argv[1], argv[2:]
        if flag == "--host":
            host = value
        elif flag == "--png":
            png = value
        else:
            sys.exit(f"unknown flag {flag}")
    if not argv:
        sys.exit(__doc__)
    method, params = argv[0], json.loads(argv[1]) if len(argv) > 1 else {}
    base = "http://" + host

    try:
        with open(_token_path(host)) as f:
            key = bytes.fromhex(f.read().strip())
    except (OSError, ValueError):
        key = pair(base, host)
    resp = call(base, key, method, params)
    if resp is None:
        resp = call(base, pair(base, host), method, params)
    if resp is None:
        sys.exit("unauthorized after re-pairing")

    result = resp.get("result")
    if png and isinstance(result, dict) and "base64" in result:
        with open(png, "wb") as f:
            f.write(base64.b64decode(result.pop("base64")))
        result["savedTo"] = os.path.abspath(png)
    print(json.dumps(resp, ensure_ascii=False, indent=2))
    return 1 if "error" in resp else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
