#!/usr/bin/env python3
"""Exercise real Matrix device revocation on a disposable loopback Synapse.

No personal accounts or pre-existing tokens are used. Cross-signing and
Olm/Megolm trust are intentionally outside this server API smoke test.
"""

import json
import secrets
import time
from urllib.error import HTTPError
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen


BASE_URL = "http://127.0.0.1"
TIMEOUT = 12


def request(method, path, *, token=None, payload=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    req = Request(BASE_URL + path, data=body, headers=headers, method=method)
    try:
        with urlopen(req, timeout=TIMEOUT) as response:
            return response.status, json.load(response)
    except HTTPError as error:
        with error:
            try:
                return error.code, json.load(error)
            except ValueError:
                return error.code, {}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def wait_until_ready():
    for _ in range(90):
        try:
            status, _ = request("GET", "/_matrix/client/versions")
            if status == 200:
                return
        except OSError:
            pass
        time.sleep(1)
    raise AssertionError("Disposable Synapse did not start")


def register(name, password):
    status, result = request(
        "POST",
        "/_matrix/client/v3/register",
        payload={
            "username": name,
            "password": password,
            "auth": {"type": "m.login.dummy"},
            "initial_device_display_name": "Disposable registration device",
        },
    )
    require(status == 200, "Disposable account registration failed")
    require(
        all(result.get(field) for field in ("user_id", "device_id", "access_token")),
        "Registration did not return a Matrix session",
    )
    return result


def login(user_id, password):
    status, result = request(
        "POST",
        "/_matrix/client/v3/login",
        payload={
            "type": "m.login.password",
            "identifier": {"type": "m.id.user", "user": user_id},
            "password": password,
            "initial_device_display_name": "Disposable device to revoke",
        },
    )
    require(status == 200, "Second device login failed")
    require(
        all(result.get(field) for field in ("device_id", "access_token")),
        "Login did not return a second session",
    )
    return result


def device_ids(token):
    status, result = request("GET", "/_matrix/client/v3/devices", token=token)
    require(status == 200, "Authenticated device listing failed")
    return {device["device_id"] for device in result.get("devices", [])}


def revoke(token, user_id, password, devices):
    payload = {"devices": devices}
    status, result = request(
        "POST", "/_matrix/client/v3/delete_devices", token=token, payload=payload
    )
    require(status == 401, "Matrix device revocation unexpectedly skipped UIA")
    require(
        any("m.login.password" in flow.get("stages", [])
            for flow in result.get("flows", [])),
        "Matrix UIA did not demand password authentication",
    )
    session = result.get("session")
    require(bool(session), "Matrix UIA did not return a session")
    status, _ = request(
        "POST",
        "/_matrix/client/v3/delete_devices",
        token=token,
        payload={
            **payload,
            "auth": {
                "type": "m.login.password",
                "identifier": {"type": "m.id.user", "user": user_id},
                "password": password,
                "session": session,
            },
        },
    )
    require(status == 200, "Authenticated Matrix device revocation failed")


def run():
    # This program must never accidentally hit a real homeserver.
    parsed = urlsplit(BASE_URL)
    require(
        parsed.scheme == "http" and parsed.hostname == "127.0.0.1",
        "Matrix smoke target must be disposable loopback Synapse",
    )
    wait_until_ready()

    suffix = secrets.token_hex(6)
    alice_password = secrets.token_urlsafe(22)
    bob_password = secrets.token_urlsafe(22)
    alice = register("revoke_a_" + suffix, alice_password)
    bob = register("revoke_b_" + suffix, bob_password)
    alice_second = login(alice["user_id"], alice_password)

    own_id = alice["device_id"]
    revoked_id = alice_second["device_id"]
    bob_id = bob["device_id"]
    require(own_id != revoked_id, "Fixture did not create distinct Matrix devices")
    require(
        {own_id, revoked_id}.issubset(device_ids(alice["access_token"])),
        "The same account cannot list both active sessions",
    )
    require(
        bob_id not in device_ids(alice["access_token"]),
        "Foreign Matrix devices leaked into account listing",
    )

    # First exercise cross-account device isolation. Matrix may accept a
    # non-existent ID as a no-op; either way Bob must retain his own session.
    revoke(alice["access_token"], alice["user_id"], alice_password, [bob_id])
    require(bob_id in device_ids(bob["access_token"]),
            "A different user's device was revoked")

    # Then revoke a real second session with UIA. The surviving session must
    # remain authenticated while the revoked access token becomes unusable.
    revoke(
        alice["access_token"], alice["user_id"], alice_password, [revoked_id]
    )
    for _ in range(8):
        if revoked_id not in device_ids(alice["access_token"]):
            break
        time.sleep(0.25)
    require(
        own_id in device_ids(alice["access_token"]) and
        revoked_id not in device_ids(alice["access_token"]),
        "Revoked device reappeared or surviving session disappeared",
    )
    status, result = request(
        "GET", "/_matrix/client/v3/devices", token=alice_second["access_token"]
    )
    require(
        status == 401 and result.get("errcode") == "M_UNKNOWN_TOKEN",
        "Revoked Matrix access token is still authorized",
    )
    # Revocation must also close the sync and E2EE key-upload boundaries, not
    # only the device-list endpoint. Never supply real cryptographic material.
    for method, endpoint, payload in (
        ("GET", "/_matrix/client/v3/sync?timeout=0", None),
        ("POST", "/_matrix/client/v3/keys/upload", {"one_time_keys": {}}),
        ("POST", "/_matrix/client/v3/keys/query", {"device_keys": {alice["user_id"]: []}}),
        ("POST", "/_matrix/client/v3/keys/claim", {"one_time_keys": {}}),
    ):
        status, result = request(
            method, endpoint, token=alice_second["access_token"], payload=payload
        )
        require(
            status == 401 and result.get("errcode") == "M_UNKNOWN_TOKEN",
            "Revoked Matrix session retains sync or encryption key API access",
        )
    status, result = request(
        "GET", "/_matrix/client/v3/sync?timeout=0", token=alice["access_token"]
    )
    require(status == 200 and bool(result.get("next_batch")),
            "Surviving Matrix session cannot sync after revocation")
    print("PASS: disposable Synapse UIA, foreign account isolation, "
          "second-device revocation, revoked sync/key upload/query/claim and surviving sync")


if __name__ == "__main__":
    run()
