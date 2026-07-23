#!/usr/bin/env python3
import asyncio
import json
import os
import sys

import websockets

RELAY_URL = f"wss://actionhub.app/?role=phone&room=actionhub&token={os.environ['DICTATE_RELAY_TOKEN']}"


async def send_presence(connection):
    while True:
        await connection.send(json.dumps({"type": "presence"}))
        await asyncio.sleep(10)


async def forward_keyboard(connection):
    event_loop = asyncio.get_running_loop()
    stdin_reader = asyncio.StreamReader()
    await event_loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(stdin_reader), sys.stdin)
    print(
        "t=take_audio  r=status recording  i=status idle  b <n>=status with buffer  "
        "m <text>=message  u <text>=committed utterance  a <text>=partial  d=playback done",
        flush=True,
    )
    while True:
        line = (await stdin_reader.readline()).decode().strip()
        if line == "t":
            await connection.send(json.dumps({"type": "take_audio"}))
        elif line == "r":
            await connection.send(json.dumps({"type": "status", "recording": True, "sending": False, "buffer": 0, "mode": "ptt"}))
        elif line == "i":
            await connection.send(json.dumps({"type": "status", "recording": False, "sending": False, "buffer": 0, "mode": "ptt"}))
        elif line.startswith("b "):
            await connection.send(json.dumps({"type": "status", "recording": True, "sending": False, "buffer": int(line[2:]), "mode": "vad"}))
        elif line.startswith("m "):
            await connection.send(json.dumps({"type": "message", "text": line[2:]}))
        elif line.startswith("u "):
            await connection.send(json.dumps({"type": "utterance", "kind": "committed", "text": line[2:]}))
        elif line.startswith("a "):
            await connection.send(json.dumps({"type": "utterance", "kind": "partial", "text": line[2:]}))
        elif line == "d":
            await connection.send(json.dumps({"type": "playback", "active": False}))


async def print_bridge_messages(connection):
    async for raw_message in connection:
        print(f"<- {raw_message}", flush=True)


async def main():
    async with websockets.connect(RELAY_URL) as connection:
        await connection.send(json.dumps({"type": "hello", "device": "fake-phone"}))
        print("connected as fake phone", flush=True)
        await asyncio.gather(
            send_presence(connection),
            forward_keyboard(connection),
            print_bridge_messages(connection),
        )


if __name__ == "__main__":
    asyncio.run(main())
