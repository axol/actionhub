import asyncio
import base64
import datetime
import hashlib
import json
import os
import sys

import websockets

from peers import load_peers, parse_pairing_data, save_peers


async def pair():
    relay_token = os.environ["DICTATE_RELAY_TOKEN"]
    relay_url = f"wss://relay.babelbase.com/?role=mac&room=actionhub&token={relay_token}"
    async with websockets.connect(relay_url) as relay_connection:
        print("waiting for a pairing request — press pair on the viewer")
        async for raw_message in relay_connection:
            if raw_message == "pong":
                continue
            try:
                event = json.loads(raw_message)
            except json.JSONDecodeError:
                continue
            if event.get("type") != "pair":
                continue
            try:
                authenticator_data = base64.b64decode(event["authenticator_data"])
                credential_id, public_key_pem, sign_count = parse_pairing_data(authenticator_data)
            except Exception as pairing_error:
                print(f"pairing request unreadable: {pairing_error!r}")
                continue
            key_fingerprint = hashlib.sha256(public_key_pem.encode()).hexdigest()
            print(f"\nkey fingerprint: {key_fingerprint[:16]} {key_fingerprint[16:32]}")
            answer = input("accept this viewer? [y/N] ").strip().lower()
            if answer != "y":
                await relay_connection.send(json.dumps({"type": "pair_rejected"}))
                print("rejected")
                continue
            peers = load_peers()
            peers[base64.b64encode(credential_id).decode()] = {
                "public_key_pem": public_key_pem,
                "sign_count": sign_count,
                "paired_at": datetime.datetime.now().isoformat(),
            }
            save_peers(peers)
            await relay_connection.send(json.dumps({"type": "paired"}))
            print("paired")
            return


if __name__ == "__main__":
    try:
        asyncio.run(pair())
    except KeyboardInterrupt:
        sys.exit(1)
