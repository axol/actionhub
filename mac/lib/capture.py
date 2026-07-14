import asyncio
import base64
import json
import sys
import time

import sounddevice
import websockets

import comms
import config
import control
import state
import status_bar

capture_runtime = {
    "task": None,
    "queue": None,
    "device": None,
    "sample_rate": None,
    "api_key": None,
    "microphone_state": None,
    "voice_activity_state": None,
    "message_buffer": None,
    "recording_state": None,
}


def configure(api_key, microphone_state, voice_activity_state, message_buffer, recording_state):
    capture_runtime["api_key"] = api_key
    capture_runtime["microphone_state"] = microphone_state
    capture_runtime["voice_activity_state"] = voice_activity_state
    capture_runtime["message_buffer"] = message_buffer
    capture_runtime["recording_state"] = recording_state


def prepare_microphone():
    device_index = resolve_microphone_device()
    capture_runtime["device"] = device_index
    capture_runtime["sample_rate"] = resolve_sample_rate(device_index)


def resolve_microphone_device():
    for device_index, device_info in enumerate(sounddevice.query_devices()):
        if device_info["max_input_channels"] > 0 and config.MICROPHONE_NAME.lower() in device_info["name"].lower():
            print(f"[microphone] {device_info['name']}", file=sys.stderr)
            return device_index
    available_names = [
        device_info["name"]
        for device_info in sounddevice.query_devices()
        if device_info["max_input_channels"] > 0
    ]
    raise SystemExit(f"microphone {config.MICROPHONE_NAME!r} not found, available: {available_names!r}")


def resolve_sample_rate(device_index):
    for candidate_rate in config.CANDIDATE_SAMPLE_RATES:
        try:
            sounddevice.check_input_settings(
                device=device_index,
                samplerate=candidate_rate,
                channels=1,
                dtype="int16",
            )
            print(f"[sample rate] {candidate_rate}", file=sys.stderr)
            return candidate_rate
        except sounddevice.PortAudioError:
            continue
    raise SystemExit(f"no supported sample rate for microphone {config.MICROPHONE_NAME!r}, tried: {config.CANDIDATE_SAMPLE_RATES!r}")


def capture_running():
    task = capture_runtime["task"]
    return task is not None and not task.done()


def start_capture():
    if capture_running():
        return
    capture_runtime["task"] = asyncio.create_task(run_capture())


def stop_capture():
    task = capture_runtime["task"]
    if task is not None and not task.done():
        task.cancel()
    capture_runtime["task"] = None


def request_commit():
    queue = capture_runtime["queue"]
    if queue is not None:
        queue.put_nowait(config.COMMIT_SENTINEL)


async def run_capture():
    audio_queue = asyncio.Queue()
    capture_runtime["queue"] = audio_queue
    event_loop = asyncio.get_running_loop()
    sample_rate = capture_runtime["sample_rate"]
    microphone_state = capture_runtime["microphone_state"]
    recording_state = capture_runtime["recording_state"]

    def enqueue_audio(input_buffer, frame_count, time_info, stream_status):
        if microphone_state["muted"] or not recording_state["recording"]:
            audio_chunk = bytes(len(input_buffer))
        else:
            audio_chunk = bytes(input_buffer)
        event_loop.call_soon_threadsafe(audio_queue.put_nowait, audio_chunk)

    try:
        with sounddevice.RawInputStream(
            device=capture_runtime["device"],
            samplerate=sample_rate,
            blocksize=sample_rate // 10,
            channels=1,
            dtype="int16",
            callback=enqueue_audio,
        ):
            await transcribe_forever(audio_queue, sample_rate)
    finally:
        state.status_bar_state["scribe"] = False
        status_bar.clear_live_partial()
        capture_runtime["queue"] = None


async def transcribe_forever(audio_queue, sample_rate):
    message_buffer = capture_runtime["message_buffer"]
    voice_activity_state = capture_runtime["voice_activity_state"]
    recording_state = capture_runtime["recording_state"]
    last_disconnect_alert = 0.0
    while True:
        try:
            async with websockets.connect(
                config.build_websocket_url(sample_rate),
                additional_headers={"xi-api-key": capture_runtime["api_key"]},
            ) as websocket_connection:
                drain_queue(audio_queue)
                await asyncio.gather(
                    stream_microphone(websocket_connection, audio_queue, sample_rate),
                    receive_transcripts(websocket_connection, message_buffer, voice_activity_state, recording_state),
                )
        except (websockets.exceptions.WebSocketException, OSError) as connection_error:
            state.status_bar_state["scribe"] = False
            status_bar.clear_live_partial()
            now = time.monotonic()
            if now - last_disconnect_alert >= config.DISCONNECT_ALERT_INTERVAL_SECONDS:
                comms.play_sound(config.DISCONNECT_SOUND)
                last_disconnect_alert = now
            print(f"[connection lost, retrying in {config.RECONNECT_DELAY_SECONDS}s] {connection_error!r}", file=sys.stderr)
            await asyncio.sleep(config.RECONNECT_DELAY_SECONDS)


async def stream_microphone(websocket_connection, audio_queue, sample_rate):
    while True:
        audio_chunk = await audio_queue.get()
        if audio_chunk is config.COMMIT_SENTINEL:
            await websocket_connection.send(json.dumps({
                "message_type": "input_audio_chunk",
                "audio_base_64": base64.b64encode(bytes(sample_rate // 10 * 2)).decode(),
                "commit": True,
                "sample_rate": sample_rate,
            }))
            continue
        await websocket_connection.send(json.dumps({
            "message_type": "input_audio_chunk",
            "audio_base_64": base64.b64encode(audio_chunk).decode(),
            "commit": False,
            "sample_rate": sample_rate,
        }))


async def receive_transcripts(websocket_connection, message_buffer, voice_activity_state, recording_state):
    async for raw_message in websocket_connection:
        message = json.loads(raw_message)
        message_type = message.get("message_type")
        if message_type == "session_started":
            state.status_bar_state["scribe"] = True
            comms.play_sound(config.CONNECT_SOUND)
            print(f"session started: {message.get('session_id')}", file=sys.stderr)
        elif message_type == "partial_transcript":
            if message["text"].strip():
                voice_activity_state["last_spoke"] = time.monotonic()
            status_bar.show_live_partial(message["text"])
        elif message_type == "committed_transcript":
            if message["text"].strip():
                voice_activity_state["last_spoke"] = time.monotonic()
            status_bar.clear_live_partial()
            control.handle_committed_utterance(message["text"], message_buffer, recording_state)
        else:
            status_bar.clear_live_partial()
            print(json.dumps(message), file=sys.stderr)
    raise ConnectionError("transcription stream ended")


def drain_queue(audio_queue):
    while not audio_queue.empty():
        audio_queue.get_nowait()
