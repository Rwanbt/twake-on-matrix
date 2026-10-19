#!/usr/bin/env python3
"""Real Olm/Megolm multi-device delivery on a disposable loopback Synapse.

This tests the Matrix protocol with libolm (not the Flutter SDK integration).
All accounts, device keys and recovery material are ephemeral.
"""

import importlib.util
import json
import secrets
from pathlib import Path
from urllib.parse import quote

from olm import (
    Account,
    InboundGroupSession,
    InboundSession,
    OlmGroupSessionError,
    OlmPreKeyMessage,
    OutboundGroupSession,
    OutboundSession,
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


def room_key_delivery(sender, recipient, room_id, group):
    # Consume only fresh to-device events for this exchange. A full sync
    # without a since cursor replays previous room_key messages, which would
    # let a rotation check inadvertently decrypt the preceding Megolm key.
    since = api("GET", "/_matrix/client/v3/sync?timeout=0", recipient.token)[
        "next_batch"
    ]
    keys = api(
        "POST",
        "/_matrix/client/v3/keys/query",
        sender.token,
        {"device_keys": {recipient.user_id: [recipient.device_id]}},
    )["device_keys"][recipient.user_id][recipient.device_id]["keys"]
    require(
        keys[f"curve25519:{recipient.device_id}"] == recipient.identity["curve25519"]
        and keys[f"ed25519:{recipient.device_id}"] == recipient.identity["ed25519"],
        "Synapse returned unexpected device identity keys",
    )
    claimed = api(
        "POST",
        "/_matrix/client/v3/keys/claim",
        sender.token,
        {"one_time_keys": {recipient.user_id: {recipient.device_id: "signed_curve25519"}}},
    )["one_time_keys"][recipient.user_id][recipient.device_id]
    claimed_keys = [value["key"] for name, value in claimed.items()
                    if name.startswith("signed_curve25519:")]
    require(len(claimed_keys) == 1, "Synapse did not return one signed Olm key")

    olm_session = OutboundSession(
        sender.account, recipient.identity["curve25519"], claimed_keys[0]
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
            "session_key": group.session_key,
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
    event = None
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
        if matching:
            event = matching[-1]
            break
    require(event is not None, "Encrypted Olm to-device delivery was not observed")
    ciphertext = event["content"]["ciphertext"][recipient.identity["curve25519"]]
    require(ciphertext["type"] == 0, "Expected Olm pre-key event")
    received = OlmPreKeyMessage(ciphertext["body"])
    inbound = InboundSession(
        recipient.account, received, sender.identity["curve25519"]
    )
    cleartext = json.loads(inbound.decrypt(received))
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
    print("PASS: real Synapse signed device/one-time keys, Olm to-device "
          "delivery, Megolm multi-device encryption and post-revocation rotation")


if __name__ == "__main__":
    run()
