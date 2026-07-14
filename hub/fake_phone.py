import asyncio
import json
import os
import sys

import websockets

RELAY_URL = f"wss://relay.babelbase.com/?role=phone&room=hub&token={os.environ['DICTATE_RELAY_TOKEN']}"


async def send_presence(connection):
    while True:
        await connection.send(json.dumps({"type": "presence"}))
        await asyncio.sleep(10)


async def forward_keyboard(connection):
    event_loop = asyncio.get_running_loop()
    stdin_reader = asyncio.StreamReader()
    await event_loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(stdin_reader), sys.stdin)
    print(
        "n=next  p=prev  u <text>=committed utterance  a <text>=partial  d=playback done  "
        "c <ptt|vad>=config  m <text>=message  b <n>=buffer count",
        flush=True,
    )
    while True:
        line = (await stdin_reader.readline()).decode().strip()
        if line == "n":
            await connection.send(json.dumps({"type": "command", "command": "nextTrackCommand"}))
        elif line == "p":
            await connection.send(json.dumps({"type": "command", "command": "previousTrackCommand"}))
        elif line.startswith("u "):
            await connection.send(json.dumps({"type": "utterance", "kind": "committed", "text": line[2:]}))
        elif line.startswith("a "):
            await connection.send(json.dumps({"type": "utterance", "kind": "partial", "text": line[2:]}))
        elif line == "d":
            await connection.send(json.dumps({"type": "playback", "active": False}))
        elif line.startswith("c "):
            await connection.send(json.dumps({"type": "config", "mode": line[2:]}))
        elif line.startswith("m "):
            await connection.send(json.dumps({"type": "message", "text": line[2:]}))
        elif line.startswith("b "):
            await connection.send(json.dumps({"type": "buffer", "count": int(line[2:])}))


async def print_hub_messages(connection):
    async for raw_message in connection:
        print(f"<- {raw_message}", flush=True)


async def main():
    async with websockets.connect(RELAY_URL) as connection:
        await connection.send(json.dumps({"type": "hello", "device": "fake-phone"}))
        print("connected as fake phone", flush=True)
        await asyncio.gather(
            send_presence(connection),
            forward_keyboard(connection),
            print_hub_messages(connection),
        )


if __name__ == "__main__":
    asyncio.run(main())
