"""Web Push (RFC 8291 payload encryption + RFC 8292 VAPID) using only `cryptography`.

Sends notifications to phones/browsers that subscribed in the app. No third-party
service, no per-message cost: the push goes through Apple's / Google's own push
servers, exactly like any app notification.
"""
import base64
import hashlib
import hmac
import json
import os
import struct
import time
from urllib.parse import urlparse

import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def unb64u(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def _hkdf_extract(salt, ikm):
    return hmac.new(salt, ikm, hashlib.sha256).digest()


def _hkdf_expand(prk, info, length):
    out, t, i = b"", b"", 1
    while len(out) < length:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        out += t
        i += 1
    return out[:length]


def _pub_bytes(pub) -> bytes:
    return pub.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def encrypt(payload: bytes, ua_public_b64: str, auth_b64: str, salt=None, as_private=None) -> bytes:
    """aes128gcm content encoding for one push message (RFC 8291 / 8188)."""
    ua_pub_raw = unb64u(ua_public_b64)
    auth = unb64u(auth_b64)
    ua_pub = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), ua_pub_raw)
    as_private = as_private or ec.generate_private_key(ec.SECP256R1())
    as_pub_raw = _pub_bytes(as_private.public_key())
    shared = as_private.exchange(ec.ECDH(), ua_pub)

    prk_key = _hkdf_extract(auth, shared)
    ikm = _hkdf_expand(prk_key, b"WebPush: info\x00" + ua_pub_raw + as_pub_raw, 32)
    salt = salt or os.urandom(16)
    prk = _hkdf_extract(salt, ikm)
    cek = _hkdf_expand(prk, b"Content-Encoding: aes128gcm\x00", 16)
    nonce = _hkdf_expand(prk, b"Content-Encoding: nonce\x00", 12)

    ciphertext = AESGCM(cek).encrypt(nonce, payload + b"\x02", None)
    header = salt + struct.pack("!I", 4096) + bytes([len(as_pub_raw)]) + as_pub_raw
    return header + ciphertext


def decrypt(body: bytes, ua_private, auth_b64: str) -> bytes:
    """Receiver side (what the phone does). Used by the tests to prove encryption is right."""
    salt, idlen = body[:16], body[20]
    as_pub_raw = body[21:21 + idlen]
    ciphertext = body[21 + idlen:]
    as_pub = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), as_pub_raw)
    ua_pub_raw = _pub_bytes(ua_private.public_key())
    shared = ua_private.exchange(ec.ECDH(), as_pub)
    prk_key = _hkdf_extract(unb64u(auth_b64), shared)
    ikm = _hkdf_expand(prk_key, b"WebPush: info\x00" + ua_pub_raw + as_pub_raw, 32)
    prk = _hkdf_extract(salt, ikm)
    cek = _hkdf_expand(prk, b"Content-Encoding: aes128gcm\x00", 16)
    nonce = _hkdf_expand(prk, b"Content-Encoding: nonce\x00", 12)
    plain = AESGCM(cek).decrypt(nonce, ciphertext, None)
    return plain.rstrip(b"\x00")[:-1]


class Vapid:
    """Server identity for push. Keys are created once and kept in vapid.json."""

    def __init__(self, path: str, subject: str = "mailto:alerts@example.com"):
        self.subject = subject
        if os.path.exists(path):
            with open(path) as f:
                pem = json.load(f)["private_pem"].encode()
            self.key = serialization.load_pem_private_key(pem, None)
        else:
            self.key = ec.generate_private_key(ec.SECP256R1())
            pem = self.key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                         serialization.NoEncryption()).decode()
            with open(path, "w") as f:
                json.dump({"private_pem": pem}, f)
        self.public_b64 = b64u(_pub_bytes(self.key.public_key()))

    def auth_header(self, endpoint: str) -> str:
        u = urlparse(endpoint)
        head = b64u(json.dumps({"typ": "JWT", "alg": "ES256"}, separators=(",", ":")).encode())
        claims = b64u(json.dumps({"aud": f"{u.scheme}://{u.netloc}", "exp": int(time.time()) + 12 * 3600,
                                  "sub": self.subject}, separators=(",", ":")).encode())
        signing_input = f"{head}.{claims}".encode()
        r, s = decode_dss_signature(self.key.sign(signing_input, ec.ECDSA(hashes.SHA256())))
        sig = b64u(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
        return f"vapid t={head}.{claims}.{sig}, k={self.public_b64}"


def send(subscription: dict, data: dict, vapid: Vapid, ttl=3600, urgency="high"):
    """Returns the HTTP status. 404/410 means the subscription is gone (app removed)."""
    body = encrypt(json.dumps(data, ensure_ascii=False).encode(), subscription["keys"]["p256dh"],
                   subscription["keys"]["auth"])
    r = requests.post(subscription["endpoint"], data=body, timeout=15, headers={
        "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream",
        "TTL": str(ttl), "Urgency": urgency, "Authorization": vapid.auth_header(subscription["endpoint"])})
    return r.status_code
