import asyncio
import atexit
import difflib
import os
import re
import sys
import termios
import tty

import capture
import claude_session
import comms
import config
import state
import status_bar


def normalize_utterance(text):
    return re.sub(r"[^a-zäöüß ]", "", text.lower()).strip()


def matches_any_phrase(normalized_text, phrases):
    return any(
        difflib.SequenceMatcher(None, normalized_text, phrase).ratio() >= config.COMMAND_MATCH_THRESHOLD
        for phrase in phrases
    )


def emit_message(message_buffer):
    message_text = " ".join(message_buffer)
    message_buffer.clear()
    emit_message_text(message_text)


def emit_message_text(message_text):
    print("\n----- message -----")
    print(message_text)
    print("-------------------\n", flush=True)
    if claude_session.deliver_message(message_text):
        comms.play_sound(config.SEND_SOUND)
    else:
        comms.play_sound(config.CANCEL_SOUND)


def handle_phone_message(message_text):
    if message_text.strip():
        emit_message_text(message_text.strip())
    else:
        print("[nothing to send]", file=sys.stderr)


def finalize_pending_send(message_buffer, recording_state):
    if not recording_state["pending_send"]:
        return
    recording_state["pending_send"] = False
    if message_buffer:
        emit_message(message_buffer)
    else:
        print("[nothing to send]", file=sys.stderr)
    if state.audio_state["owner"] == "mac":
        recording_state["recording"] = True
        print("[listening]", file=sys.stderr)
    comms.send_phone_state(recording_state)


async def finalize_send_after_timeout(message_buffer, recording_state):
    await asyncio.sleep(config.DRAIN_TIMEOUT_SECONDS)
    if recording_state["pending_send"]:
        print("[drain timeout, sending what was transcribed]", file=sys.stderr)
        finalize_pending_send(message_buffer, recording_state)


def handle_committed_utterance(text, message_buffer, recording_state):
    utterance = text.strip()
    normalized_text = normalize_utterance(utterance)
    if recording_state["pending_send"]:
        if normalized_text and not matches_any_phrase(normalized_text, config.SEND_PHRASES):
            message_buffer.append(utterance)
            print(f"[{len(message_buffer)}] {utterance}", file=sys.stderr)
        finalize_pending_send(message_buffer, recording_state)
        return
    if not normalized_text:
        return
    if not recording_state["recording"]:
        print(f"[idle utterance ignored] {utterance}", file=sys.stderr)
        return
    if matches_any_phrase(normalized_text, config.SEND_PHRASES):
        if message_buffer:
            emit_message(message_buffer)
        else:
            print("[nothing to send]", file=sys.stderr)
        comms.send_phone_state(recording_state)
    else:
        message_buffer.append(utterance)
        comms.play_sound(config.UTTERANCE_SOUND, config.UTTERANCE_VOLUME)
        print(f"[{len(message_buffer)}] {utterance}", file=sys.stderr)


def toggle_audio_owner(message_buffer, recording_state):
    if state.audio_state["owner"] == "mac":
        state.audio_state["owner"] = "phone"
        recording_state["recording"] = False
        recording_state["pending_send"] = False
        capture.stop_capture()
        print("[phone audio]", file=sys.stderr)
    else:
        state.audio_state["owner"] = "mac"
        recording_state["recording"] = True
        recording_state["pending_send"] = False
        capture.start_capture()
        comms.play_sound(config.RECORD_SOUND)
        print("[mac audio, listening]", file=sys.stderr)
    comms.send_phone_state(recording_state)
    status_bar.render_status_bar()


def handle_keyboard_command(command, message_buffer, playback_state, recording_state):
    print(f"[key] {command}", file=sys.stderr)
    if state.audio_state["owner"] != "mac":
        print("[phone owns audio, press v to take it]", file=sys.stderr)
        return
    if command == "previous":
        if playback_state["active"]:
            playback_state["stop_requested"] = True
            recording_state["recording"] = True
            comms.play_sound(config.RECORD_SOUND)
            print("[playback stopped, listening]", file=sys.stderr)
        elif recording_state["recording"]:
            message_buffer.clear()
            comms.play_sound(config.STOP_SOUND)
            print("[buffer discarded]", file=sys.stderr)
        elif recording_state["pending_send"]:
            recording_state["pending_send"] = False
            message_buffer.clear()
            comms.play_sound(config.STOP_SOUND)
            recording_state["recording"] = True
            print("[send cancelled, listening]", file=sys.stderr)
        return
    if recording_state["recording"]:
        recording_state["recording"] = False
        recording_state["pending_send"] = True
        capture.request_commit()
        print("[waiting for final transcript...]", file=sys.stderr)
        asyncio.create_task(finalize_send_after_timeout(message_buffer, recording_state))
    elif recording_state["pending_send"]:
        print("[already sending]", file=sys.stderr)
    else:
        recording_state["recording"] = True
        capture.start_capture()
        comms.play_sound(config.RECORD_SOUND)
        print("[listening]", file=sys.stderr)


def setup_keyboard(event_loop, message_buffer, playback_state, recording_state):
    if not sys.stdin.isatty():
        return
    stdin_descriptor = sys.stdin.fileno()
    original_terminal_attributes = termios.tcgetattr(stdin_descriptor)
    tty.setcbreak(stdin_descriptor)
    atexit.register(termios.tcsetattr, stdin_descriptor, termios.TCSADRAIN, original_terminal_attributes)

    def on_keyboard_input():
        key_bytes = os.read(stdin_descriptor, 16)
        if key_bytes == b"\x1b[C":
            handle_keyboard_command("next", message_buffer, playback_state, recording_state)
        elif key_bytes == b"\x1b[D":
            handle_keyboard_command("previous", message_buffer, playback_state, recording_state)
        elif key_bytes in (b"v", b"V"):
            toggle_audio_owner(message_buffer, recording_state)

    event_loop.add_reader(stdin_descriptor, on_keyboard_input)
    print("[keys] right=send  left=discard  v=mac/phone audio", file=sys.stderr)
