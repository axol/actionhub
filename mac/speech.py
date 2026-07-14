import asyncio
import json
import os
import sys
import time
import urllib.request

import sounddevice

import comms
import config
import state


def queue_speak_request(text):
    file_name = f"speak-{int(time.time() * 1000)}-repeat.json"
    temporary_path = os.path.join(config.SPEAK_DIRECTORY, f".{file_name}")
    with open(temporary_path, "w") as speak_file:
        json.dump({"text": text}, speak_file)
    os.rename(temporary_path, os.path.join(config.SPEAK_DIRECTORY, file_name))


def stream_speech_playback(text, playback_state):
    tts_request = urllib.request.Request(
        config.TTS_URL,
        data=json.dumps({"text": text, "model_id": config.TTS_MODEL}).encode(),
        headers={
            "xi-api-key": os.environ["ELEVENLABS_API_KEY"],
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(tts_request) as tts_response:
        with sounddevice.RawOutputStream(
            samplerate=config.TTS_SAMPLE_RATE,
            channels=1,
            dtype="int16",
        ) as output_stream:
            while not playback_state["stop_requested"]:
                pcm_chunk = tts_response.read(config.TTS_CHUNK_BYTES)
                if not pcm_chunk:
                    break
                output_stream.write(pcm_chunk)


async def speak_text(text, microphone_state, speech_state, playback_state):
    microphone_state["muted"] = True
    speech_state["last_text"] = text
    playback_state["stop_requested"] = False
    playback_state["active"] = True
    try:
        comms.play_sound(config.TTS_START_SOUND)
        print(f"[speaking] {text}", file=sys.stderr)
        await asyncio.to_thread(stream_speech_playback, text, playback_state)
    finally:
        playback_state["active"] = False
        await asyncio.sleep(0.1 if playback_state["stop_requested"] else 0.4)
        microphone_state["muted"] = False


def user_recently_spoke(voice_activity_state):
    return time.monotonic() - voice_activity_state["last_spoke"] < config.SPEAK_IDLE_SECONDS


async def consume_speak_requests(microphone_state, voice_activity_state, speech_state, playback_state, recording_state, message_buffer):
    os.makedirs(config.SPEAK_DIRECTORY, exist_ok=True)
    while True:
        for file_name in sorted(os.listdir(config.SPEAK_DIRECTORY)):
            if file_name.startswith("."):
                continue
            file_path = os.path.join(config.SPEAK_DIRECTORY, file_name)
            try:
                with open(file_path) as speak_file:
                    speak_request = json.load(speak_file)
            except Exception as parse_error:
                print(f"[speak request unreadable] {parse_error!r}", file=sys.stderr)
                os.remove(file_path)
                continue
            if "sound" in speak_request:
                os.remove(file_path)
                print("[channel ack]", file=sys.stderr)
                continue
            phone_busy = state.audio_state["owner"] == "phone" and (
                state.phone_state["sending"]
                or state.phone_state["buffer_count"]
                or (state.phone_state["mode"] == "ptt" and state.phone_state["recording"])
            )
            if (
                phone_busy
                or recording_state["pending_send"]
                or message_buffer
                or user_recently_spoke(voice_activity_state)
            ):
                break
            os.remove(file_path)
            if state.audio_state["owner"] == "phone":
                if state.phone_link["connection"] is None:
                    print(f"[no phone for playback] {speak_request['text']}", file=sys.stderr)
                    continue
                speech_state["last_text"] = speak_request["text"]
                playback_state["stop_requested"] = False
                playback_state["active"] = True
                comms.send_phone_message({"type": "speak", "text": speak_request["text"]})
                print(f"[speaking on phone] {speak_request['text']}", file=sys.stderr)
                continue
            try:
                await speak_text(speak_request["text"], microphone_state, speech_state, playback_state)
            except Exception as speak_error:
                print(f"[speak failed] {speak_error!r}", file=sys.stderr)
        await asyncio.sleep(0.5)
