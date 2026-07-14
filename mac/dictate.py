import asyncio
import atexit
import base64
import datetime
import difflib
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import termios
import time
import tty
import urllib.request

import sounddevice
import websockets
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

MICROPHONE_NAME = os.environ.get("DICTATE_MICROPHONE", "MacBook Air Microphone")
CANDIDATE_SAMPLE_RATES = (16000, 24000, 44100, 48000)


def build_websocket_url(sample_rate):
    return (
        "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
        "?model_id=scribe_v2_realtime"
        f"&audio_format=pcm_{sample_rate}"
        "&commit_strategy=vad"
        "&vad_silence_threshold_secs=1.0"
    )

SEND_PHRASES = ("the message is now complete",)
COMMAND_MATCH_THRESHOLD = 0.8
SOUNDS_DIRECTORY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sounds")
SEND_SOUND = os.path.join(SOUNDS_DIRECTORY, "sent.mp3")
CANCEL_SOUND = "/System/Library/Sounds/Basso.aiff"
TTS_START_SOUND = "/System/Library/Sounds/Pop.aiff"
CONNECT_SOUND = "/System/Library/Sounds/Ping.aiff"
DISCONNECT_SOUND = "/System/Library/Sounds/Sosumi.aiff"
UTTERANCE_SOUND = os.path.join(SOUNDS_DIRECTORY, "click.mp3")
UTTERANCE_VOLUME = 1.0
EVENT_SOUNDS = {"delivered": os.path.join(SOUNDS_DIRECTORY, "delivered.mp3")}
ACTIVITY_SOUND = os.path.join(SOUNDS_DIRECTORY, "tick.mp3")
ACTIVITY_VOLUME = 1.0
THINKING_SOUND = os.path.join(SOUNDS_DIRECTORY, "think.mp3")
THINKING_VOLUME = 0.35
RESPONSE_SOUND = os.path.join(SOUNDS_DIRECTORY, "response.mp3")
RECORD_SOUND = os.path.join(SOUNDS_DIRECTORY, "record.mp3")
STOP_SOUND = os.path.join(SOUNDS_DIRECTORY, "stop.mp3")
FAILED_SOUND = os.path.join(SOUNDS_DIRECTORY, "failed.mp3")
ACK_TIMEOUT_SECONDS = 10
ACTIVITY_COOLDOWN_SECONDS = 1.5
CLAUDE_PROJECTS_DIRECTORY = os.path.expanduser("~/.claude/projects")
RECONNECT_DELAY_SECONDS = 3
DISCONNECT_ALERT_INTERVAL_SECONDS = 15
SPEAK_IDLE_SECONDS = 1.5

DRAIN_TIMEOUT_SECONDS = 2.5
COMMIT_SENTINEL = object()

VOICE_BASE_DIRECTORY = "/tmp/claude-voice"
REGISTRY_DIRECTORY = os.path.join(VOICE_BASE_DIRECTORY, "registry")
SPEAK_DIRECTORY = os.path.join(VOICE_BASE_DIRECTORY, "speak")

TTS_VOICE_ID = "CotBdG05uF4hQYtylCDX"
TTS_MODEL = "eleven_v3"
TTS_SAMPLE_RATE = 24000
TTS_URL = f"https://api.elevenlabs.io/v1/text-to-speech/{TTS_VOICE_ID}/stream?output_format=pcm_{TTS_SAMPLE_RATE}"
TTS_CHUNK_BYTES = 4800

STATUS_REFRESH_SECONDS = 0.25
SESSION_CHECK_INTERVAL_SECONDS = 2.0
STATUS_BAR_ROWS = 3

PHONE_PRESENCE_TIMEOUT_SECONDS = 25

status_bar_state = {
    "enabled": False,
    "partial": "",
    "scribe": False,
    "relay": False,
    "phone_last_seen": 0.0,
    "session_pid": None,
    "message_buffer": None,
    "recording_state": None,
    "playback_state": None,
}

audio_state = {"owner": "phone"}
phone_state = {"mode": "ptt", "recording": False, "sending": False, "buffer_count": 0}
phone_link = {"connection": None}
observed_lock = {"fingerprint": None, "fingerprint_time": 0.0, "hint_printed": False}
pending_ack = {"text": None, "confirmed": True}

PEERS_FILE = os.path.expanduser("~/.config/actionhub/peers.json")
CHALLENGE_LIFETIME_SECONDS = 120

pending_pairing = {"request": None}
pending_challenges = {}


def parse_cbor_item(data, offset):
    initial_byte = data[offset]
    major_type = initial_byte >> 5
    additional = initial_byte & 0x1F
    offset += 1
    if additional < 24:
        argument = additional
    elif additional == 24:
        argument = data[offset]
        offset += 1
    elif additional == 25:
        argument = int.from_bytes(data[offset:offset + 2], "big")
        offset += 2
    elif additional == 26:
        argument = int.from_bytes(data[offset:offset + 4], "big")
        offset += 4
    else:
        raise ValueError(f"unsupported cbor additional info {additional}")
    if major_type == 0:
        return argument, offset
    if major_type == 1:
        return -1 - argument, offset
    if major_type == 2:
        return data[offset:offset + argument], offset + argument
    if major_type == 3:
        return data[offset:offset + argument].decode(), offset + argument
    if major_type == 5:
        decoded_map = {}
        for _ in range(argument):
            key, offset = parse_cbor_item(data, offset)
            value, offset = parse_cbor_item(data, offset)
            decoded_map[key] = value
        return decoded_map, offset
    raise ValueError(f"unsupported cbor major type {major_type}")


def cose_key_to_pem(cose_key):
    x_coordinate = int.from_bytes(cose_key[-2], "big")
    y_coordinate = int.from_bytes(cose_key[-3], "big")
    public_key = ec.EllipticCurvePublicNumbers(x_coordinate, y_coordinate, ec.SECP256R1()).public_key()
    return public_key.public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode()


def parse_pairing_data(authenticator_data):
    sign_count = int.from_bytes(authenticator_data[33:37], "big")
    credential_id_length = int.from_bytes(authenticator_data[53:55], "big")
    credential_id = authenticator_data[55:55 + credential_id_length]
    cose_key, _ = parse_cbor_item(authenticator_data, 55 + credential_id_length)
    return credential_id, cose_key_to_pem(cose_key), sign_count


def load_peers():
    try:
        with open(PEERS_FILE) as peers_file:
            return json.load(peers_file)
    except (OSError, json.JSONDecodeError):
        return {}


def save_peers(peers):
    os.makedirs(os.path.dirname(PEERS_FILE), exist_ok=True)
    with open(PEERS_FILE, "w") as peers_file:
        json.dump(peers, peers_file, indent=2)


def handle_pair_request(pair_event):
    try:
        authenticator_data = base64.b64decode(pair_event["authenticator_data"])
        credential_id, public_key_pem, sign_count = parse_pairing_data(authenticator_data)
    except Exception as pairing_error:
        print(f"[pairing request unreadable] {pairing_error!r}", file=sys.stderr)
        return
    key_fingerprint = hashlib.sha256(public_key_pem.encode()).hexdigest()[:16]
    pending_pairing["request"] = {
        "credential_id": base64.b64encode(credential_id).decode(),
        "public_key_pem": public_key_pem,
        "sign_count": sign_count,
    }
    print(f"[pairing request] key fingerprint {key_fingerprint} — press y to accept, n to reject", file=sys.stderr)


def accept_pairing():
    request = pending_pairing["request"]
    if request is None:
        return
    pending_pairing["request"] = None
    peers = load_peers()
    peers[request["credential_id"]] = {
        "public_key_pem": request["public_key_pem"],
        "sign_count": request["sign_count"],
        "paired_at": datetime.datetime.now().isoformat(),
    }
    save_peers(peers)
    send_phone_message({"type": "paired"})
    print("[pairing accepted]", file=sys.stderr)


def reject_pairing():
    if pending_pairing["request"] is None:
        return
    pending_pairing["request"] = None
    send_phone_message({"type": "pair_rejected"})
    print("[pairing rejected]", file=sys.stderr)


def issue_challenge():
    now = time.monotonic()
    expired_nonces = [nonce for nonce, issued_at in pending_challenges.items() if now - issued_at > CHALLENGE_LIFETIME_SECONDS]
    for nonce in expired_nonces:
        del pending_challenges[nonce]
    nonce = base64.b64encode(secrets.token_bytes(32)).decode()
    pending_challenges[nonce] = now
    send_phone_message({"type": "challenge", "nonce": nonce})
    print("[challenge issued]", file=sys.stderr)


def reject_viewer_action(reason):
    print(f"[viewer action rejected: {reason}]", file=sys.stderr)
    send_phone_message({"type": "activity", "kind": "error", "text": f"viewer action rejected: {reason}"})


def handle_viewer_action(action_event):
    nonce = action_event.get("nonce", "")
    issued_at = pending_challenges.pop(nonce, None)
    if issued_at is None or time.monotonic() - issued_at > CHALLENGE_LIFETIME_SECONDS:
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
    send_phone_message({"type": "activity", "kind": "received", "text": f"viewer action verified: {action.get('kind')}"})


def normalize_utterance(text):
    return re.sub(r"[^a-zäöüß ]", "", text.lower()).strip()


def matches_any_phrase(normalized_text, phrases):
    return any(
        difflib.SequenceMatcher(None, normalized_text, phrase).ratio() >= COMMAND_MATCH_THRESHOLD
        for phrase in phrases
    )


async def deliver_phone_message(phone_connection, payload):
    try:
        await phone_connection.send(json.dumps(payload))
    except (websockets.exceptions.WebSocketException, OSError):
        pass


def send_phone_message(payload):
    phone_connection = phone_link["connection"]
    if phone_connection is None:
        return
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return
    asyncio.create_task(deliver_phone_message(phone_connection, payload))


def send_phone_state(recording_state):
    send_phone_message({"type": "state", "audio": audio_state["owner"]})


def play_sound(sound_file, volume=None):
    if audio_state["owner"] == "phone":
        sound_name = os.path.splitext(os.path.basename(sound_file))[0]
        send_phone_message({"type": "sound", "name": sound_name})
        return
    command = ["afplay"]
    if volume is not None:
        command += ["-v", str(volume)]
    subprocess.Popen(command + [sound_file])


def resolve_microphone_device():
    for device_index, device_info in enumerate(sounddevice.query_devices()):
        if device_info["max_input_channels"] > 0 and MICROPHONE_NAME.lower() in device_info["name"].lower():
            print(f"[microphone] {device_info['name']}", file=sys.stderr)
            return device_index
    available_names = [
        device_info["name"]
        for device_info in sounddevice.query_devices()
        if device_info["max_input_channels"] > 0
    ]
    raise SystemExit(f"microphone {MICROPHONE_NAME!r} not found, available: {available_names!r}")


def resolve_sample_rate(device_index):
    for candidate_rate in CANDIDATE_SAMPLE_RATES:
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
    raise SystemExit(f"no supported sample rate for microphone {MICROPHONE_NAME!r}, tried: {CANDIDATE_SAMPLE_RATES!r}")


def find_live_voice_session():
    if not os.path.isdir(REGISTRY_DIRECTORY):
        return None
    live_entries = []
    for file_name in os.listdir(REGISTRY_DIRECTORY):
        registry_path = os.path.join(REGISTRY_DIRECTORY, file_name)
        try:
            with open(registry_path) as registry_file:
                registry_entry = json.load(registry_file)
        except (OSError, json.JSONDecodeError):
            continue
        try:
            os.kill(registry_entry["claudeProcessId"], 0)
        except ProcessLookupError:
            os.remove(registry_path)
            continue
        live_entries.append(registry_entry)
    if not live_entries:
        return None
    return max(live_entries, key=lambda registry_entry: registry_entry["startedAt"])


def deliver_message(message_text):
    session_entry = find_live_voice_session()
    if session_entry is None:
        print("[no live claude session with voice channel]", file=sys.stderr)
        return False
    file_name = f"message-{int(time.time() * 1000)}.txt"
    temporary_path = os.path.join(session_entry["inboxDirectory"], f".{file_name}")
    final_path = os.path.join(session_entry["inboxDirectory"], file_name)
    with open(temporary_path, "w") as message_file:
        message_file.write(message_text)
    os.rename(temporary_path, final_path)
    observed_lock["fingerprint"] = message_text[:80]
    observed_lock["fingerprint_time"] = time.time()
    pending_ack["text"] = message_text[:80]
    pending_ack["confirmed"] = False
    asyncio.create_task(alert_unconfirmed_delivery())
    print(f"[delivered to claude pid {session_entry['claudeProcessId']}]", file=sys.stderr)
    return True


async def alert_unconfirmed_delivery():
    ack_text = pending_ack["text"]
    await asyncio.sleep(ACK_TIMEOUT_SECONDS)
    if pending_ack["confirmed"] or pending_ack["text"] != ack_text:
        return
    play_sound(FAILED_SOUND)
    send_phone_message({"type": "activity", "kind": "error", "text": "delivery not confirmed"})
    print("[delivery not confirmed, session may not have voice channel]", file=sys.stderr)


def emit_message(message_buffer):
    message_text = " ".join(message_buffer)
    message_buffer.clear()
    emit_message_text(message_text)


def emit_message_text(message_text):
    print("\n----- message -----")
    print(message_text)
    print("-------------------\n", flush=True)
    if deliver_message(message_text):
        play_sound(SEND_SOUND)
    else:
        play_sound(CANCEL_SOUND)


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
    if audio_state["owner"] == "mac":
        recording_state["recording"] = True
        print("[listening]", file=sys.stderr)
    send_phone_state(recording_state)


async def finalize_send_after_timeout(message_buffer, recording_state):
    await asyncio.sleep(DRAIN_TIMEOUT_SECONDS)
    if recording_state["pending_send"]:
        print("[drain timeout, sending what was transcribed]", file=sys.stderr)
        finalize_pending_send(message_buffer, recording_state)


def handle_committed_utterance(text, message_buffer, recording_state):
    utterance = text.strip()
    normalized_text = normalize_utterance(utterance)
    if recording_state["pending_send"]:
        if normalized_text and not matches_any_phrase(normalized_text, SEND_PHRASES):
            message_buffer.append(utterance)
            print(f"[{len(message_buffer)}] {utterance}", file=sys.stderr)
        finalize_pending_send(message_buffer, recording_state)
        return
    if not normalized_text:
        return
    if not recording_state["recording"]:
        print(f"[idle utterance ignored] {utterance}", file=sys.stderr)
        return
    if matches_any_phrase(normalized_text, SEND_PHRASES):
        if message_buffer:
            emit_message(message_buffer)
        else:
            print("[nothing to send]", file=sys.stderr)
        send_phone_state(recording_state)
    else:
        message_buffer.append(utterance)
        play_sound(UTTERANCE_SOUND, UTTERANCE_VOLUME)
        print(f"[{len(message_buffer)}] {utterance}", file=sys.stderr)


def stream_speech_playback(text, playback_state):
    tts_request = urllib.request.Request(
        TTS_URL,
        data=json.dumps({"text": text, "model_id": TTS_MODEL}).encode(),
        headers={
            "xi-api-key": os.environ["ELEVENLABS_API_KEY"],
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(tts_request) as tts_response:
        with sounddevice.RawOutputStream(
            samplerate=TTS_SAMPLE_RATE,
            channels=1,
            dtype="int16",
        ) as output_stream:
            while not playback_state["stop_requested"]:
                pcm_chunk = tts_response.read(TTS_CHUNK_BYTES)
                if not pcm_chunk:
                    break
                output_stream.write(pcm_chunk)


async def speak_text(text, microphone_state, speech_state, playback_state):
    microphone_state["muted"] = True
    speech_state["last_text"] = text
    playback_state["stop_requested"] = False
    playback_state["active"] = True
    try:
        play_sound(TTS_START_SOUND)
        print(f"[speaking] {text}", file=sys.stderr)
        await asyncio.to_thread(stream_speech_playback, text, playback_state)
    finally:
        playback_state["active"] = False
        await asyncio.sleep(0.1 if playback_state["stop_requested"] else 0.4)
        microphone_state["muted"] = False


def user_recently_spoke(voice_activity_state):
    return time.monotonic() - voice_activity_state["last_spoke"] < SPEAK_IDLE_SECONDS


async def consume_speak_requests(microphone_state, voice_activity_state, speech_state, playback_state, recording_state, message_buffer):
    os.makedirs(SPEAK_DIRECTORY, exist_ok=True)
    while True:
        for file_name in sorted(os.listdir(SPEAK_DIRECTORY)):
            if file_name.startswith("."):
                continue
            file_path = os.path.join(SPEAK_DIRECTORY, file_name)
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
            phone_busy = audio_state["owner"] == "phone" and (
                phone_state["sending"]
                or phone_state["buffer_count"]
                or (phone_state["mode"] == "ptt" and phone_state["recording"])
            )
            if (
                phone_busy
                or recording_state["pending_send"]
                or message_buffer
                or user_recently_spoke(voice_activity_state)
            ):
                break
            os.remove(file_path)
            if audio_state["owner"] == "phone":
                if phone_link["connection"] is None:
                    print(f"[no phone for playback] {speak_request['text']}", file=sys.stderr)
                    continue
                speech_state["last_text"] = speak_request["text"]
                playback_state["stop_requested"] = False
                playback_state["active"] = True
                send_phone_message({"type": "speak", "text": speak_request["text"]})
                print(f"[speaking on phone] {speak_request['text']}", file=sys.stderr)
                continue
            try:
                await speak_text(speak_request["text"], microphone_state, speech_state, playback_state)
            except Exception as speak_error:
                print(f"[speak failed] {speak_error!r}", file=sys.stderr)
        await asyncio.sleep(0.5)


def munge_project_path(project_path):
    return re.sub(r"[^A-Za-z0-9]", "-", project_path)


def session_transcript_candidates(working_directory):
    transcript_directory = os.path.join(CLAUDE_PROJECTS_DIRECTORY, munge_project_path(working_directory))
    if not os.path.isdir(transcript_directory):
        return []
    return [
        os.path.join(transcript_directory, file_name)
        for file_name in os.listdir(transcript_directory)
        if file_name.endswith(".jsonl")
    ]


def parse_started_at(started_at_text):
    try:
        return datetime.datetime.fromisoformat(started_at_text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def locate_session_transcript(session_entry):
    candidate_paths = session_transcript_candidates(session_entry["workingDirectory"])
    session_start = parse_started_at(session_entry["startedAt"])
    for candidate_path in candidate_paths:
        try:
            birth_time = os.stat(candidate_path).st_birthtime
        except OSError:
            continue
        if abs(birth_time - session_start) < 15:
            return candidate_path
    fingerprint = observed_lock["fingerprint"]
    if not fingerprint:
        return None
    for candidate_path in candidate_paths:
        try:
            if os.path.getmtime(candidate_path) < observed_lock["fingerprint_time"] - 5:
                continue
            with open(candidate_path, "rb") as transcript_file:
                transcript_file.seek(max(0, os.path.getsize(candidate_path) - 262144))
                tail_text = transcript_file.read().decode("utf-8", errors="ignore")
        except OSError:
            continue
        if fingerprint in tail_text:
            return candidate_path
    return None


def extract_user_text(entry):
    message = entry.get("message") or {}
    if message.get("role") != "user":
        return ""
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            block.get("text", "")
            for block in content
            if isinstance(block, dict) and block.get("type") == "text"
        )
    return ""


def confirm_pending_ack(entry):
    if pending_ack["confirmed"] or not pending_ack["text"]:
        return
    if pending_ack["text"] not in extract_user_text(entry):
        return
    pending_ack["confirmed"] = True
    clear_live_partial()
    play_sound(EVENT_SOUNDS["delivered"])
    send_phone_message({"type": "activity", "kind": "received", "text": "message received"})
    print("[claude received the message]", file=sys.stderr)


def classify_transcript_line(entry):
    message = entry.get("message") or {}
    content = message.get("content")
    if not isinstance(content, list):
        return None
    blocks = [block for block in content if isinstance(block, dict)]
    tool_names = [block.get("name") for block in blocks if block.get("type") == "tool_use" and block.get("name")]
    if tool_names:
        return ("tool_use", " ".join(tool_names))
    if any(block.get("type") == "thinking" for block in blocks):
        return ("thinking", "thinking")
    if message.get("role") == "assistant":
        text = " ".join(block.get("text", "") for block in blocks if block.get("type") == "text").strip()
        if text:
            return ("response", text[:2000])
    return None


async def observe_transcript():
    transcript_path = None
    transcript_file = None
    pending_text = ""
    last_activity_sound = 0.0
    while True:
        await asyncio.sleep(1)
        session_entry = find_live_voice_session()
        if session_entry is None:
            continue
        current_path = locate_session_transcript(session_entry)
        if current_path is None:
            if not observed_lock["hint_printed"]:
                observed_lock["hint_printed"] = True
                print("[transcript not locked, send a message to calibrate]", file=sys.stderr)
            continue
        if current_path != transcript_path:
            if transcript_file:
                transcript_file.close()
            transcript_file = open(current_path)
            transcript_file.seek(0, os.SEEK_END)
            transcript_path = current_path
            pending_text = ""
            observed_lock["hint_printed"] = False
            print(f"[observing transcript] {transcript_path}", file=sys.stderr)
        chunk = transcript_file.read()
        if not chunk:
            continue
        pending_text += chunk
        lines = pending_text.split("\n")
        pending_text = lines.pop()
        for line in lines:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            confirm_pending_ack(entry)
            classified_event = classify_transcript_line(entry)
            if classified_event is None:
                continue
            event_kind, event_description = classified_event
            clear_live_partial()
            print(f"[claude] {event_description}", file=sys.stderr)
            send_phone_message({"type": "activity", "kind": event_kind, "text": event_description})
            if event_kind == "response":
                play_sound(RESPONSE_SOUND)
                continue
            now = time.monotonic()
            if now - last_activity_sound < ACTIVITY_COOLDOWN_SECONDS:
                continue
            last_activity_sound = now
            if event_kind == "thinking":
                play_sound(THINKING_SOUND, THINKING_VOLUME)
            else:
                play_sound(ACTIVITY_SOUND, ACTIVITY_VOLUME)


def queue_speak_request(text):
    file_name = f"speak-{int(time.time() * 1000)}-repeat.json"
    temporary_path = os.path.join(SPEAK_DIRECTORY, f".{file_name}")
    with open(temporary_path, "w") as speak_file:
        json.dump({"text": text}, speak_file)
    os.rename(temporary_path, os.path.join(SPEAK_DIRECTORY, file_name))


def toggle_audio_owner(message_buffer, recording_state):
    if audio_state["owner"] == "mac":
        audio_state["owner"] = "phone"
        recording_state["recording"] = False
        recording_state["pending_send"] = False
        print("[phone audio]", file=sys.stderr)
    else:
        audio_state["owner"] = "mac"
        recording_state["recording"] = True
        recording_state["pending_send"] = False
        play_sound(RECORD_SOUND)
        print("[mac audio, listening]", file=sys.stderr)
    send_phone_state(recording_state)
    render_status_bar()


def handle_keyboard_command(command, message_buffer, playback_state, recording_state, audio_queue):
    print(f"[key] {command}", file=sys.stderr)
    if audio_state["owner"] != "mac":
        print("[phone owns audio, press v to take it]", file=sys.stderr)
        return
    if command == "previous":
        if playback_state["active"]:
            playback_state["stop_requested"] = True
            recording_state["recording"] = True
            play_sound(RECORD_SOUND)
            print("[playback stopped, listening]", file=sys.stderr)
        elif recording_state["recording"]:
            message_buffer.clear()
            play_sound(STOP_SOUND)
            print("[buffer discarded]", file=sys.stderr)
        elif recording_state["pending_send"]:
            recording_state["pending_send"] = False
            message_buffer.clear()
            play_sound(STOP_SOUND)
            recording_state["recording"] = True
            print("[send cancelled, listening]", file=sys.stderr)
        return
    if recording_state["recording"]:
        recording_state["recording"] = False
        recording_state["pending_send"] = True
        audio_queue.put_nowait(COMMIT_SENTINEL)
        print("[waiting for final transcript...]", file=sys.stderr)
        asyncio.create_task(finalize_send_after_timeout(message_buffer, recording_state))
    elif recording_state["pending_send"]:
        print("[already sending]", file=sys.stderr)
    else:
        recording_state["recording"] = True
        play_sound(RECORD_SOUND)
        print("[listening]", file=sys.stderr)


def setup_keyboard(event_loop, message_buffer, playback_state, recording_state, audio_queue):
    if not sys.stdin.isatty():
        return
    stdin_descriptor = sys.stdin.fileno()
    original_terminal_attributes = termios.tcgetattr(stdin_descriptor)
    tty.setcbreak(stdin_descriptor)
    atexit.register(termios.tcsetattr, stdin_descriptor, termios.TCSADRAIN, original_terminal_attributes)

    def on_keyboard_input():
        key_bytes = os.read(stdin_descriptor, 16)
        if key_bytes == b"\x1b[C":
            handle_keyboard_command("next", message_buffer, playback_state, recording_state, audio_queue)
        elif key_bytes == b"\x1b[D":
            handle_keyboard_command("previous", message_buffer, playback_state, recording_state, audio_queue)
        elif key_bytes in (b"v", b"V"):
            toggle_audio_owner(message_buffer, recording_state)
        elif key_bytes in (b"y", b"Y"):
            accept_pairing()
        elif key_bytes in (b"n", b"N"):
            reject_pairing()

    event_loop.add_reader(stdin_descriptor, on_keyboard_input)
    print("[keys] right=send  left=discard  v=mac/phone audio", file=sys.stderr)


def render_status_bar():
    if not status_bar_state["enabled"]:
        return
    recording_state = status_bar_state["recording_state"]
    playback_state = status_bar_state["playback_state"]
    if audio_state["owner"] == "mac":
        currently_sending = recording_state["pending_send"]
        currently_recording = recording_state["recording"]
    else:
        currently_sending = phone_state["sending"]
        currently_recording = phone_state["recording"]
    if currently_sending:
        activity = "sending"
    elif currently_recording:
        if audio_state["owner"] == "mac" or phone_state["mode"] == "vad":
            activity = "listening"
        else:
            activity = "RECORDING"
    elif playback_state["active"]:
        activity = "speaking"
    else:
        activity = "idle"
    scribe_marker = "●" if status_bar_state["scribe"] else "○"
    relay_marker = "●" if status_bar_state["relay"] else "○"
    phone_present = time.monotonic() - status_bar_state["phone_last_seen"] < PHONE_PRESENCE_TIMEOUT_SECONDS
    phone_marker = "●" if phone_present else "○"
    session_pid = status_bar_state["session_pid"]
    claude_marker = str(session_pid) if session_pid else "○"
    if audio_state["owner"] == "mac":
        buffer_count = len(status_bar_state["message_buffer"])
    else:
        buffer_count = phone_state["buffer_count"]
    segments = [
        f"audio {audio_state['owner']} {activity}",
        f"scribe {scribe_marker}",
        f"relay {relay_marker}",
        f"phone {phone_marker}",
        f"claude {claude_marker}",
        f"buffer {buffer_count}",
    ]
    status_line = " " + "  ·  ".join(segments)
    columns, rows = shutil.get_terminal_size()
    if len(status_line) > columns:
        status_line = status_line[:columns - 1] + "…"
    partial_lines = wrap_partial_lines(columns)
    first_row = rows - STATUS_BAR_ROWS + 1
    output = f"\0337\033[{first_row};1H\033[7m{status_line.ljust(columns)}\033[0m"
    for row_offset in range(1, STATUS_BAR_ROWS):
        partial_line = partial_lines[row_offset - 1] if row_offset - 1 < len(partial_lines) else ""
        output += f"\033[{first_row + row_offset};1H\033[2m{partial_line.ljust(columns)}\033[0m"
    sys.stderr.write(output + "\0338")
    sys.stderr.flush()


def wrap_partial_lines(columns):
    if not status_bar_state["partial"]:
        return []
    partial_text = f"… {status_bar_state['partial']}"
    chunk_width = max(columns - 1, 10)
    chunks = [partial_text[start:start + chunk_width] for start in range(0, len(partial_text), chunk_width)]
    return chunks[-(STATUS_BAR_ROWS - 1):]


def apply_scroll_region():
    columns, rows = shutil.get_terminal_size()
    top_of_bar = rows - STATUS_BAR_ROWS + 1
    clear_bar_rows = "".join(f"\033[{row};1H\033[K" for row in range(top_of_bar, rows + 1))
    sys.stderr.write(f"{clear_bar_rows}\033[1;{top_of_bar - 1}r\033[{top_of_bar - 1};1H")
    sys.stderr.flush()


def teardown_status_bar():
    if not status_bar_state["enabled"]:
        return
    status_bar_state["enabled"] = False
    columns, rows = shutil.get_terminal_size()
    top_of_bar = rows - STATUS_BAR_ROWS + 1
    clear_bar_rows = "".join(f"\033[{row};1H\033[K" for row in range(top_of_bar, rows + 1))
    sys.stderr.write(f"\033[r{clear_bar_rows}")
    sys.stderr.flush()


def setup_status_bar(message_buffer, recording_state, playback_state):
    if not sys.stderr.isatty():
        return
    status_bar_state["message_buffer"] = message_buffer
    status_bar_state["recording_state"] = recording_state
    status_bar_state["playback_state"] = playback_state
    status_bar_state["enabled"] = True
    apply_scroll_region()
    atexit.register(teardown_status_bar)
    render_status_bar()


def handle_terminal_resize():
    if not status_bar_state["enabled"]:
        return
    apply_scroll_region()
    render_status_bar()


async def refresh_status_bar():
    if not status_bar_state["enabled"]:
        return
    last_session_check = 0.0
    while True:
        now = time.monotonic()
        if now - last_session_check >= SESSION_CHECK_INTERVAL_SECONDS:
            last_session_check = now
            session_entry = find_live_voice_session()
            status_bar_state["session_pid"] = session_entry["claudeProcessId"] if session_entry else None
        render_status_bar()
        await asyncio.sleep(STATUS_REFRESH_SECONDS)


def handle_phone_event(phone_event, voice_activity_state, playback_state, recording_state):
    status_bar_state["phone_last_seen"] = time.monotonic()
    event_type = phone_event.get("type")
    if event_type == "presence":
        return
    if event_type == "hello":
        print(f"[phone] {phone_event.get('device')}", file=sys.stderr)
        send_phone_state(recording_state)
    elif event_type == "take_audio":
        if audio_state["owner"] != "phone":
            audio_state["owner"] = "phone"
            recording_state["recording"] = False
            recording_state["pending_send"] = False
            print("[phone took audio]", file=sys.stderr)
        send_phone_state(recording_state)
    elif event_type == "status":
        previously_recording = phone_state["recording"]
        phone_state["mode"] = phone_event.get("mode", phone_state["mode"])
        phone_state["recording"] = bool(phone_event.get("recording"))
        phone_state["sending"] = bool(phone_event.get("sending"))
        phone_state["buffer_count"] = int(phone_event.get("buffer", 0))
        if phone_state["recording"] != previously_recording:
            print("[phone recording]" if phone_state["recording"] else "[phone idle]", file=sys.stderr)
    elif event_type == "utterance":
        text = phone_event.get("text", "")
        if text.strip():
            voice_activity_state["last_spoke"] = time.monotonic()
        if phone_event.get("kind") == "committed":
            clear_live_partial()
            if text.strip():
                print(f"[phone] {text.strip()}", file=sys.stderr)
        else:
            show_live_partial(text)
    elif event_type == "message":
        handle_phone_message(phone_event.get("text", ""))
    elif event_type == "pair":
        handle_pair_request(phone_event)
    elif event_type == "challenge_request":
        issue_challenge()
    elif event_type == "action":
        handle_viewer_action(phone_event)
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
                phone_link["connection"] = phone_connection
                status_bar_state["relay"] = True
                print("[relay connected]", file=sys.stderr)
                send_phone_state(recording_state)
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
            phone_link["connection"] = None
            status_bar_state["relay"] = False
        await asyncio.sleep(5)


def show_live_partial(text):
    if status_bar_state["enabled"]:
        status_bar_state["partial"] = text.strip()
        render_status_bar()
        return
    terminal_width = shutil.get_terminal_size().columns
    line = f"… {text}"
    if len(line) >= terminal_width:
        line = "…" + line[-(terminal_width - 2):]
    print(f"\r\033[K{line}", end="", file=sys.stderr, flush=True)


def clear_live_partial():
    if status_bar_state["enabled"]:
        status_bar_state["partial"] = ""
        render_status_bar()
        return
    print("\r\033[K", end="", file=sys.stderr, flush=True)


async def stream_microphone(websocket_connection, audio_queue, sample_rate):
    while True:
        audio_chunk = await audio_queue.get()
        if audio_chunk is COMMIT_SENTINEL:
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
            status_bar_state["scribe"] = True
            play_sound(CONNECT_SOUND)
            print(f"session started: {message.get('session_id')}", file=sys.stderr)
        elif message_type == "partial_transcript":
            if message["text"].strip():
                voice_activity_state["last_spoke"] = time.monotonic()
            show_live_partial(message["text"])
        elif message_type == "committed_transcript":
            if message["text"].strip():
                voice_activity_state["last_spoke"] = time.monotonic()
            clear_live_partial()
            handle_committed_utterance(message["text"], message_buffer, recording_state)
        else:
            clear_live_partial()
            print(json.dumps(message), file=sys.stderr)
    raise ConnectionError("transcription stream ended")


def drain_queue(audio_queue):
    while not audio_queue.empty():
        audio_queue.get_nowait()


async def transcribe_forever(api_key, audio_queue, message_buffer, voice_activity_state, recording_state, sample_rate):
    last_disconnect_alert = 0.0
    while True:
        try:
            async with websockets.connect(
                build_websocket_url(sample_rate),
                additional_headers={"xi-api-key": api_key},
            ) as websocket_connection:
                drain_queue(audio_queue)
                await asyncio.gather(
                    stream_microphone(websocket_connection, audio_queue, sample_rate),
                    receive_transcripts(websocket_connection, message_buffer, voice_activity_state, recording_state),
                )
        except (websockets.exceptions.WebSocketException, OSError) as connection_error:
            status_bar_state["scribe"] = False
            clear_live_partial()
            now = time.monotonic()
            if now - last_disconnect_alert >= DISCONNECT_ALERT_INTERVAL_SECONDS:
                play_sound(DISCONNECT_SOUND)
                last_disconnect_alert = now
            print(f"[connection lost, retrying in {RECONNECT_DELAY_SECONDS}s] {connection_error!r}", file=sys.stderr)
            await asyncio.sleep(RECONNECT_DELAY_SECONDS)


async def main():
    api_key = os.environ["ELEVENLABS_API_KEY"]
    event_loop = asyncio.get_running_loop()
    audio_queue = asyncio.Queue()
    message_buffer = []
    microphone_state = {"muted": False}
    voice_activity_state = {"last_spoke": 0.0}
    speech_state = {"last_text": None}
    playback_state = {"active": False, "stop_requested": False}
    recording_state = {"recording": False, "pending_send": False}

    def enqueue_audio(input_buffer, frame_count, time_info, status):
        if microphone_state["muted"] or not recording_state["recording"] or audio_state["owner"] != "mac":
            audio_chunk = bytes(len(input_buffer))
        else:
            audio_chunk = bytes(input_buffer)
        event_loop.call_soon_threadsafe(audio_queue.put_nowait, audio_chunk)

    microphone_device = resolve_microphone_device()
    sample_rate = resolve_sample_rate(microphone_device)
    with sounddevice.RawInputStream(
        device=microphone_device,
        samplerate=sample_rate,
        blocksize=sample_rate // 10,
        channels=1,
        dtype="int16",
        callback=enqueue_audio,
    ):
        setup_status_bar(message_buffer, recording_state, playback_state)
        event_loop.add_signal_handler(signal.SIGWINCH, handle_terminal_resize)
        setup_keyboard(event_loop, message_buffer, playback_state, recording_state, audio_queue)
        print("[audio: phone] press v to switch to mac listening", file=sys.stderr)
        await asyncio.gather(
            transcribe_forever(api_key, audio_queue, message_buffer, voice_activity_state, recording_state, sample_rate),
            consume_speak_requests(microphone_state, voice_activity_state, speech_state, playback_state, recording_state, message_buffer),
            observe_transcript(),
            consume_phone_events(voice_activity_state, playback_state, recording_state),
            refresh_status_bar(),
        )


if __name__ == "__main__":
    asyncio.run(main())
