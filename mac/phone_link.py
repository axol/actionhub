import asyncio
import json
import os
import sys
import time

import websockets

import comms
import control
import state
import status_bar
import verification


def handle_phone_event(phone_event, voice_activity_state, playback_state, recording_state):
    state.status_bar_state["phone_last_seen"] = time.monotonic()
    event_type = phone_event.get("type")
    if event_type == "presence":
        return
    if event_type == "hello":
        print(f"[phone] {phone_event.get('device')}", file=sys.stderr)
        comms.send_phone_state(recording_state)
    elif event_type == "take_audio":
        if state.audio_state["owner"] != "phone":
            state.audio_state["owner"] = "phone"
            recording_state["recording"] = False
            recording_state["pending_send"] = False
            import capture
            capture.stop_capture()
            print("[phone took audio]", file=sys.stderr)
        comms.send_phone_state(recording_state)
    elif event_type == "status":
        previously_recording = state.phone_state["recording"]
        state.phone_state["mode"] = phone_event.get("mode", state.phone_state["mode"])
        state.phone_state["recording"] = bool(phone_event.get("recording"))
        state.phone_state["sending"] = bool(phone_event.get("sending"))
        state.phone_state["buffer_count"] = int(phone_event.get("buffer", 0))
        if state.phone_state["recording"] != previously_recording:
            print("[phone recording]" if state.phone_state["recording"] else "[phone idle]", file=sys.stderr)
    elif event_type == "utterance":
        text = phone_event.get("text", "")
        if text.strip():
            voice_activity_state["last_spoke"] = time.monotonic()
        if phone_event.get("kind") == "committed":
            status_bar.clear_live_partial()
            if text.strip():
                print(f"[phone] {text.strip()}", file=sys.stderr)
        else:
            status_bar.show_live_partial(text)
    elif event_type == "message":
        control.handle_phone_message(phone_event.get("text", ""))
    elif event_type == "pair":
        print("[pairing request received — run mac/pair.py for the pairing ceremony]", file=sys.stderr)
    elif event_type == "challenge_request":
        verification.issue_challenge()
    elif event_type == "action":
        verification.handle_viewer_action(phone_event)
    elif event_type == "playback":
        playback_state["active"] = bool(phone_event.get("active"))


async def consume_phone_events(voice_activity_state, playback_state, recording_state):
    relay_token = os.environ.get("DICTATE_RELAY_TOKEN")
    if not relay_token:
        print("[relay disabled, DICTATE_RELAY_TOKEN not set]", file=sys.stderr)
        return
    relay_url = f"wss://relay.babelbase.com/?role=mac&room=actionhub&token={relay_token}"
    while True:
        try:
            async with websockets.connect(relay_url) as phone_connection:
                state.phone_link["connection"] = phone_connection
                state.status_bar_state["relay"] = True
                print("[relay connected]", file=sys.stderr)
                comms.send_phone_state(recording_state)
                async for raw_message in phone_connection:
                    if raw_message == "pong":
                        continue
                    try:
                        phone_event = json.loads(raw_message)
                    except json.JSONDecodeError:
                        continue
                    handle_phone_event(phone_event, voice_activity_state, playback_state, recording_state)
        except (websockets.exceptions.WebSocketException, OSError) as relay_error:
            print(f"[relay disconnected, retrying in 5s] {relay_error!r}", file=sys.stderr)
        finally:
            state.phone_link["connection"] = None
            state.status_bar_state["relay"] = False
        await asyncio.sleep(5)
