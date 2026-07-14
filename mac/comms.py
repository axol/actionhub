import asyncio
import json
import os
import subprocess

import websockets

import state


async def deliver_phone_message(phone_connection, payload):
    try:
        await phone_connection.send(json.dumps(payload))
    except (websockets.exceptions.WebSocketException, OSError):
        pass


def send_phone_message(payload):
    phone_connection = state.phone_link["connection"]
    if phone_connection is None:
        return
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return
    asyncio.create_task(deliver_phone_message(phone_connection, payload))


def send_phone_state(recording_state):
    send_phone_message({"type": "state", "audio": state.audio_state["owner"]})


def play_sound(sound_file, volume=None):
    if state.audio_state["owner"] == "phone":
        sound_name = os.path.splitext(os.path.basename(sound_file))[0]
        send_phone_message({"type": "sound", "name": sound_name})
        return
    command = ["afplay"]
    if volume is not None:
        command += ["-v", str(volume)]
    subprocess.Popen(command + [sound_file])
