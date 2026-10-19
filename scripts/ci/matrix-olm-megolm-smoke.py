#!/usr/bin/env python3
"""Real Olm/Megolm multi-device delivery on a disposable loopback Synapse.

This tests the Matrix protocol with libolm (not the Flutter SDK integration).
All accounts, device keys and recovery material are ephemeral.
"""

import importlib.util
import json
import secrets
from copy import deepcopy
from pathlib import Path
from urllib.parse import quote

from olm import (
    Account,
    InboundGroupSession,
    InboundSession,
    OlmGroupSessionError,
    OlmPreKeyMessage,
    OlmVerifyError,
    OutboundGroupSession,
    OutboundSession,
    ed25519_verify,
)


spec = importlib.util.spec_from_file_location(
    "matrix_revocation_smoke",
    Path(__file__).with_name("matrix-device-revocation-smoke.py"),
)
assert spec is not None and spec.loader is not None
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
request = smoke.request
require = smoke.require


def canonical(payload):
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def verify_signed_json(payload, user_id, signing_key_id, signing_public_key):
    """Verify Matrix canonical JSON; signatures and unsigned are not signed."""
    signature = payload["signatures"][user_id][signing_key_id]
    signed = {k: v for k, v in payload.items() if k not in ("signatures", "unsigned")}
    ed25519_verify(signing_public_key, canonical(signed), signature)


def reject_tampered_signed_key(signed_key, user_id, signing_key_id, public_key):
    tampered = deepcopy(signed_key)
    first = tampered["key"][0]
    tampered["key"] = ("A" if first != "A" else "B") + tampered["key"][1:]
    try:
        verify_signed_json(tampered, user_id, signing_key_id, public_key)
    except OlmVerifyError:
        return
    raise AssertionError("A tampered signed one-time Olm key was trusted")


def api(method, path, token, payload=None):
    status, body = request(method, path, token=token, payload=payload)
    require(status == 200, f"Matrix {method} {path.split('?')[0]} failed ({status})")
    return body


def path_id(identifier):
    return quote(identifier, safe="")


class Device:
    def __init__(self, session):
        self.user_id = session["user_id"]
        self.device_id = session["device_id"]
        self.token = session["access_token"]
        self.account = Account()
        self.identity = self.account.identity_keys

    def publish_keys(self):
        self.account.generate_one_time_keys(3)
        device_keys = {
            "user_id": self.user_id,
            "device_id": self.device_id,
            "algorithms": [
                "m.olm.v1.curve25519-aes-sha2",
                "m.megolm.v1.aes-sha2",
            ],
            "keys": {
                f"curve25519:{self.device_id}": self.identity["curve25519"],
                f"ed25519:{self.device_id}": self.identity["ed25519"],
            },
        }
        device_keys["signatures"] = {
            self.user_id: {
                f"ed25519:{self.device_id}": self.account.sign(canonical(device_keys))
            }
        }
        one_time_keys = {}
        for key_id, key in self.account.one_time_keys["curve25519"].items():
            signed_key = {"key": key}
            signed_key["signatures"] = {
                self.user_id: {
                    f"ed25519:{self.device_id}": self.account.sign(canonical(signed_key))
                }
            }
            one_time_keys[f"signed_curve25519:{key_id}"] = signed_key
        result = api(
            "POST",
            "/_matrix/client/v3/keys/upload",
            self.token,
            {"device_keys": device_keys, "one_time_keys": one_time_keys},
        )
        require(
            result.get("one_time_key_counts", {}).get("signed_curve25519", 0) >= 1,
            "Real one-time Olm keys were not uploaded",
        )
        self.account.mark_keys_as_published()


def make_signing_key(user_id, usage, signer):
    key = signer.identity_keys["ed25519"]
    return {
        "user_id": user_id,
        "usage": [usage],
        "keys": {f"ed25519:{key}": key},
    }


def sign_json(payload, user_id, signer):
    signed = deepcopy(payload)
    public = signer.identity_keys["ed25519"]
    signed.setdefault("signatures", {}).setdefault(user_id, {})[
        f"ed25519:{public}"
    ] = signer.sign(canonical({
        key: value for key, value in signed.items()
        if key not in ("signatures", "unsigned")
    }))
    return signed


def verify_cross_signing(user, peer):
    # Cross-signing lives in the Matrix homeserver, not in a mocked device
    # list. The peer may see master + self signing, but not our user signing key.
    queried = api(
        "POST", "/_matrix/client/v3/keys/query", peer.token,
        {"device_keys": {user.user_id: []}},
    )
    master = queried["master_keys"][user.user_id]
    self_signed = queried["self_signing_keys"][user.user_id]
    master_public = next(iter(master["keys"].values()))
    self_public = next(iter(self_signed["keys"].values()))
    verify_signed_json(self_signed, user.user_id,
                       f"ed25519:{master_public}", master_public)
    require(user.user_id not in queried.get("user_signing_keys", {}),
            "A peer was given another user's private trust-signing identity")
    return master_public, self_public


def sign_device(user, device, self_signer, peer):
    device_key = api(
        "POST", "/_matrix/client/v3/keys/query", user.token,
        {"device_keys": {device.user_id: [device.device_id]}},
    )["device_keys"][device.user_id][device.device_id]
    signed_device = sign_json(device_key, user.user_id, self_signer)
    response = api(
        "POST", "/_matrix/client/v3/keys/signatures/upload", user.token,
        {user.user_id: {device.device_id: signed_device}},
    )
    require(not response.get("failures"), "Synapse rejected self-signed device")
    _, self_public = verify_cross_signing(user, peer)
    seen = api(
        "POST", "/_matrix/client/v3/keys/query", peer.token,
        {"device_keys": {user.user_id: [device.device_id]}},
    )["device_keys"][user.user_id][device.device_id]
    verify_signed_json(seen, user.user_id, f"ed25519:{self_public}", self_public)
    return seen


def publish_cross_signing(user, password, devices, peer):
    master, self_signer, user_signer = Account(), Account(), Account()
    master_key = make_signing_key(user.user_id, "master", master)
    self_key = sign_json(
        make_signing_key(user.user_id, "self_signing", self_signer),
        user.user_id, master,
    )
    user_key = sign_json(
        make_signing_key(user.user_id, "user_signing", user_signer),
        user.user_id, master,
    )
    payload = {
        "master_key": master_key,
        "self_signing_key": self_key,
        "user_signing_key": user_key,
    }
    status, body = request(
        "POST", "/_matrix/client/v3/keys/device_signing/upload",
        token=user.token, payload=payload,
    )
    if status == 401:
        require(
            any("m.login.password" in flow.get("stages", [])
                for flow in body.get("flows", [])),
            "Cross-signing upload omitted required password UIA stage",
        )
        payload["auth"] = {
            "type": "m.login.password",
            "identifier": {"type": "m.id.user", "user": user.user_id},
            "password": password,
            "session": body["session"],
        }
        status, body = request(
            "POST", "/_matrix/client/v3/keys/device_signing/upload",
            token=user.token, payload=payload,
        )
    require(status == 200, f"Matrix cross-signing upload failed ({status})")
    master_public, self_public = verify_cross_signing(user, peer)
    require(
        master_public == master.identity_keys["ed25519"]
        and self_public == self_signer.identity_keys["ed25519"],
        "Cross-signing chain changed between upload and key query",
    )
    for device in devices:
        sign_device(user, device, self_signer, peer)
    return self_signer


def room_key_delivery(sender, recipient, room_id, group, session_key=None):
    # Consume only fresh to-device events for this exchange. A full sync
    # without a since cursor replays previous room_key messages, which would
    # let a rotation check inadvertently decrypt the preceding Megolm key.
    since = api("GET", "/_matrix/client/v3/sync?timeout=0", recipient.token)[
        "next_batch"
    ]
    device = api(
        "POST",
        "/_matrix/client/v3/keys/query",
        sender.token,
        {"device_keys": {recipient.user_id: [recipient.device_id]}},
    )["device_keys"][recipient.user_id][recipient.device_id]
    require(
        device["user_id"] == recipient.user_id
        and device["device_id"] == recipient.device_id,
        "Queried Olm device key belongs to a different Matrix identity",
    )
    keys = device["keys"]
    require(
        keys[f"curve25519:{recipient.device_id}"] == recipient.identity["curve25519"]
        and keys[f"ed25519:{recipient.device_id}"] == recipient.identity["ed25519"],
        "Synapse returned unexpected device identity keys",
    )
    signing_key_id = f"ed25519:{recipient.device_id}"
    verify_signed_json(
        device, recipient.user_id, signing_key_id, recipient.identity["ed25519"]
    )
    claimed = api(
        "POST",
        "/_matrix/client/v3/keys/claim",
        sender.token,
        {"one_time_keys": {recipient.user_id: {recipient.device_id: "signed_curve25519"}}},
    )["one_time_keys"][recipient.user_id][recipient.device_id]
    signed_keys = [value for name, value in claimed.items()
                   if name.startswith("signed_curve25519:")]
    require(len(signed_keys) == 1, "Synapse did not return one signed Olm key")
    signed_key = signed_keys[0]
    verify_signed_json(
        signed_key, recipient.user_id, signing_key_id, recipient.identity["ed25519"]
    )
    reject_tampered_signed_key(
        signed_key, recipient.user_id, signing_key_id, recipient.identity["ed25519"]
    )

    olm_session = OutboundSession(
        sender.account, recipient.identity["curve25519"], signed_key["key"]
    )
    secret = {
        "type": "m.room_key",
        "sender": sender.user_id,
        "recipient": recipient.user_id,
        "recipient_keys": {"ed25519": recipient.identity["ed25519"]},
        "keys": {"ed25519": sender.identity["ed25519"]},
        "content": {
            "algorithm": "m.megolm.v1.aes-sha2",
            "room_id": room_id,
            "session_id": group.id,
            "session_key": group.session_key if session_key is None else session_key,
        },
    }
    encrypted = olm_session.encrypt(canonical(secret))
    require(encrypted.message_type == 0, "First Olm message is not a pre-key message")
    api(
        "PUT",
        "/_matrix/client/v3/sendToDevice/m.room.encrypted/" + secrets.token_hex(12),
        sender.token,
        {
            "messages": {
                recipient.user_id: {
                    recipient.device_id: {
                        "algorithm": "m.olm.v1.curve25519-aes-sha2",
                        "sender_key": sender.identity["curve25519"],
                        "ciphertext": {
                            recipient.identity["curve25519"]: {
                                "type": encrypted.message_type,
                                "body": encrypted.ciphertext,
                            }
                        },
                    }
                }
            }
        },
    )
    cleartext = None
    for _ in range(8):
        sync = api(
            "GET",
            "/_matrix/client/v3/sync?timeout=1000&since=" + path_id(since),
            recipient.token,
        )
        since = sync["next_batch"]
        matching = [
            e for e in sync.get("to_device", {}).get("events", [])
            if e.get("type") == "m.room.encrypted"
            and e.get("content", {}).get("sender_key") == sender.identity["curve25519"]
        ]
        for event in matching:
            ciphertext = event["content"]["ciphertext"].get(
                recipient.identity["curve25519"]
            )
            if ciphertext is None or ciphertext["type"] != 0:
                continue
            received = OlmPreKeyMessage(ciphertext["body"])
            # Another still-pending Olm room_key can arrive during rotation.
            # Only accept the key for the expected Megolm session epoch.
            try:
                inbound = InboundSession(
                    recipient.account, received, sender.identity["curve25519"]
                )
                decoded = json.loads(inbound.decrypt(received))
            except (ValueError, KeyError):
                continue
            if decoded.get("content", {}).get("session_id") == group.id:
                cleartext = decoded
                break
        if cleartext is not None:
            break
    require(cleartext is not None, "Expected Olm room key epoch was not delivered")
    require(
        cleartext["sender"] == sender.user_id
        and cleartext["recipient"] == recipient.user_id
        and cleartext["recipient_keys"]["ed25519"] == recipient.identity["ed25519"]
        and cleartext["content"]["room_id"] == room_id
        and cleartext["content"]["session_id"] == group.id,
        "Decrypted Olm room key has an incorrect sender, recipient or session",
    )
    return InboundGroupSession(cleartext["content"]["session_key"])


def encrypted_room_event(sender, room_id, group, text):
    content = {
        "room_id": room_id,
        "type": "m.room.message",
        "content": {"msgtype": "m.text", "body": text},
    }
    ciphertext = group.encrypt(canonical(content))
    result = api(
        "PUT",
        f"/_matrix/client/v3/rooms/{path_id(room_id)}/send/m.room.encrypted/"
        + secrets.token_hex(12),
        sender.token,
        {
            "algorithm": "m.megolm.v1.aes-sha2",
            "sender_key": sender.identity["curve25519"],
            "device_id": sender.device_id,
            "session_id": group.id,
            "ciphertext": ciphertext,
        },
    )
    return result["event_id"], ciphertext


def inspect_room_event(recipient, room_id, event_id, ciphertext, group, body):
    # Each recipient independently fetches the exact Matrix event using its
    # access token, then decrypts it with its Olm-delivered Megolm room key.
    # A full /sync timeline can be limited or omit older events.
    event = api(
        "GET",
        f"/_matrix/client/v3/rooms/{path_id(room_id)}/event/{path_id(event_id)}",
        recipient.token,
    )
    require(
        event["type"] == "m.room.encrypted"
        and event["content"]["ciphertext"] == ciphertext
        and body not in canonical(event),
        "Synapse returned an unencrypted or mismatched room message",
    )
    decrypted, index = group.decrypt(event["content"]["ciphertext"])
    require(
        json.loads(decrypted)["content"]["body"] == body and index == 0,
        "Megolm failed to decrypt the delivered room message",
    )


def run():
    # The imported smoke module independently enforces 127.0.0.1 loopback.
    smoke.wait_until_ready()
    suffix = secrets.token_hex(6)
    password = secrets.token_urlsafe(20)
    alice_first = smoke.register("olm_a_" + suffix, password)
    alice_second = smoke.login(alice_first["user_id"], password)
    bob = smoke.register("olm_b_" + suffix, secrets.token_urlsafe(20))
    first, second, peer = map(Device, (alice_first, alice_second, bob))
    require(first.device_id != second.device_id, "Multi-device fixture not distinct")
    for device in (first, second, peer):
        device.publish_keys()
    self_signer = publish_cross_signing(first, password, (first, second), peer)

    room_id = api(
        "POST",
        "/_matrix/client/v3/createRoom",
        first.token,
        {
            "preset": "private_chat",
            "invite": [peer.user_id],
            "initial_state": [{
                "type": "m.room.encryption", "state_key": "",
                "content": {"algorithm": "m.megolm.v1.aes-sha2"},
            }],
        },
    )["room_id"]
    api("POST", f"/_matrix/client/v3/rooms/{path_id(room_id)}/join", peer.token, {})

    original = OutboundGroupSession()
    original_session_key = original.session_key
    second_key = room_key_delivery(first, second, room_id, original)
    peer_key = room_key_delivery(first, peer, room_id, original)
    first_id, first_ciphertext = encrypted_room_event(
        first, room_id, original, "first encrypted message"
    )
    for recipient, key in ((second, second_key), (peer, peer_key)):
        inspect_room_event(
            recipient, room_id, first_id, first_ciphertext, key,
            "first encrypted message",
        )

    # Revoke the second Alice device and rotate Megolm to a fresh session.
    # The old key must not decrypt the new epoch, even if cached locally.
    smoke.revoke(first.token, first.user_id, password, [second.device_id])
    status, revoked = request(
        "POST", "/_matrix/client/v3/keys/query",
        token=second.token, payload={"device_keys": {first.user_id: []}},
    )
    require(status == 401 and revoked.get("errcode") == "M_UNKNOWN_TOKEN",
            "Revoked device still has Matrix key-query authorization")
    rotated = OutboundGroupSession()
    require(rotated.id != original.id, "Megolm rotation reused the session")
    rotated_session_key = rotated.session_key
    rotated_peer_key = room_key_delivery(first, peer, room_id, rotated)
    new_id, new_ciphertext = encrypted_room_event(
        first, room_id, rotated, "message after device revocation"
    )
    inspect_room_event(
        peer, room_id, new_id, new_ciphertext, rotated_peer_key,
        "message after device revocation",
    )
    try:
        second_key.decrypt(new_ciphertext)
    except OlmGroupSessionError:
        pass
    else:
        raise AssertionError("Revoked device's previous Megolm key decrypted new epoch")

    # A replacement device cannot read history from a later Megolm epoch.
    # Only an explicitly authorized, encrypted Olm room-key transfer restores
    # that history. A device revoked above never receives the replacement key.
    replacement = Device(smoke.login(first.user_id, password))
    replacement.publish_keys()
    require(replacement.device_id not in (first.device_id, second.device_id),
            "Replacement Matrix device reused a revoked identity")
    sign_device(first, replacement, self_signer, peer)
    replacement_current_key = room_key_delivery(
        first, replacement, room_id, rotated, session_key=rotated_session_key
    )
    inspect_room_event(
        replacement, room_id, new_id, new_ciphertext, replacement_current_key,
        "message after device revocation",
    )
    try:
        replacement_current_key.decrypt(first_ciphertext)
    except OlmGroupSessionError:
        pass
    else:
        raise AssertionError("New device decrypted earlier history without key recovery")
    replacement_historical_key = room_key_delivery(
        first, replacement, room_id, original, session_key=original_session_key
    )
    inspect_room_event(
        replacement, room_id, first_id, first_ciphertext,
        replacement_historical_key, "first encrypted message",
    )
    print("PASS: real Synapse signed device/one-time keys, Olm to-device "
          "delivery, signature tampering rejection, cross-signing hierarchy, "
          "Megolm rotation and explicit replacement-device history recovery")


if __name__ == "__main__":
    run()
