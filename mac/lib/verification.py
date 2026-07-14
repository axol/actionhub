import base64
import hashlib
import json
import secrets
import sys
import time

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

import comms
import config
import state
from peers import load_peers, save_peers


def issue_challenge():
    now = time.monotonic()
    expired_nonces = [
        nonce
        for nonce, issued_at in state.pending_challenges.items()
        if now - issued_at > config.CHALLENGE_LIFETIME_SECONDS
    ]
    for nonce in expired_nonces:
        del state.pending_challenges[nonce]
    nonce = base64.b64encode(secrets.token_bytes(32)).decode()
    state.pending_challenges[nonce] = now
    comms.send_phone_message({"type": "challenge", "nonce": nonce})
    print("[challenge issued]", file=sys.stderr)


def reject_viewer_action(reason):
    print(f"[viewer action rejected: {reason}]", file=sys.stderr)
    comms.send_phone_message({"type": "activity", "kind": "error", "text": f"viewer action rejected: {reason}"})


def handle_viewer_action(action_event):
    nonce = action_event.get("nonce", "")
    issued_at = state.pending_challenges.pop(nonce, None)
    if issued_at is None or time.monotonic() - issued_at > config.CHALLENGE_LIFETIME_SECONDS:
        reject_viewer_action("unknown or expired nonce")
        return
    peers = load_peers()
    peer = peers.get(action_event.get("credential_id", ""))
    if peer is None:
        reject_viewer_action("unknown credential")
        return
    try:
        authenticator_data = base64.b64decode(action_event["authenticator_data"])
        signature = base64.b64decode(action_event["signature"])
        action_text = action_event["action"]
        client_data_hash = hashlib.sha256(action_text.encode() + base64.b64decode(nonce)).digest()
        public_key = serialization.load_pem_public_key(peer["public_key_pem"].encode())
        public_key.verify(signature, authenticator_data + client_data_hash, ec.ECDSA(hashes.SHA256()))
    except Exception as verification_error:
        reject_viewer_action(f"verification failed {verification_error!r}")
        return
    if not authenticator_data[32] & 0x04:
        reject_viewer_action("no user verification flag")
        return
    sign_count = int.from_bytes(authenticator_data[33:37], "big")
    if sign_count <= peer["sign_count"]:
        reject_viewer_action(f"sign count not increasing ({sign_count} <= {peer['sign_count']})")
        return
    peer["sign_count"] = sign_count
    save_peers(peers)
    action = json.loads(action_text)
    print(f"[viewer action verified] {action!r}", file=sys.stderr)
    comms.send_phone_message({"type": "activity", "kind": "received", "text": f"viewer action verified: {action.get('kind')}"})
