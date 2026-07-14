import asyncio
import datetime
import json
import os
import re
import sys
import time

import comms
import config
import state
import status_bar


def munge_project_path(project_path):
    return re.sub(r"[^A-Za-z0-9]", "-", project_path)


def session_transcript_candidates(working_directory):
    transcript_directory = os.path.join(config.CLAUDE_PROJECTS_DIRECTORY, munge_project_path(working_directory))
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


def find_live_voice_session():
    if not os.path.isdir(config.REGISTRY_DIRECTORY):
        return None
    live_entries = []
    for file_name in os.listdir(config.REGISTRY_DIRECTORY):
        registry_path = os.path.join(config.REGISTRY_DIRECTORY, file_name)
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
    state.observed_lock["fingerprint"] = message_text[:80]
    state.observed_lock["fingerprint_time"] = time.time()
    state.pending_ack["text"] = message_text[:80]
    state.pending_ack["confirmed"] = False
    asyncio.create_task(alert_unconfirmed_delivery())
    print(f"[delivered to claude pid {session_entry['claudeProcessId']}]", file=sys.stderr)
    return True


async def alert_unconfirmed_delivery():
    ack_text = state.pending_ack["text"]
    await asyncio.sleep(config.ACK_TIMEOUT_SECONDS)
    if state.pending_ack["confirmed"] or state.pending_ack["text"] != ack_text:
        return
    comms.play_sound(config.FAILED_SOUND)
    comms.send_phone_message({"type": "activity", "kind": "error", "text": "delivery not confirmed"})
    print("[delivery not confirmed, session may not have voice channel]", file=sys.stderr)


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
    fingerprint = state.observed_lock["fingerprint"]
    if not fingerprint:
        return None
    for candidate_path in candidate_paths:
        try:
            if os.path.getmtime(candidate_path) < state.observed_lock["fingerprint_time"] - 5:
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
    if state.pending_ack["confirmed"] or not state.pending_ack["text"]:
        return
    if state.pending_ack["text"] not in extract_user_text(entry):
        return
    state.pending_ack["confirmed"] = True
    status_bar.clear_live_partial()
    comms.play_sound(config.EVENT_SOUNDS["delivered"])
    comms.send_phone_message({"type": "activity", "kind": "received", "text": "message received"})
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
            if not state.observed_lock["hint_printed"]:
                state.observed_lock["hint_printed"] = True
                print("[transcript not locked, send a message to calibrate]", file=sys.stderr)
            continue
        if current_path != transcript_path:
            if transcript_file:
                transcript_file.close()
            transcript_file = open(current_path)
            transcript_file.seek(0, os.SEEK_END)
            transcript_path = current_path
            pending_text = ""
            state.observed_lock["hint_printed"] = False
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
            status_bar.clear_live_partial()
            print(f"[claude] {event_description}", file=sys.stderr)
            comms.send_phone_message({"type": "activity", "kind": event_kind, "text": event_description})
            if event_kind == "response":
                comms.play_sound(config.RESPONSE_SOUND)
                continue
            now = time.monotonic()
            if now - last_activity_sound < config.ACTIVITY_COOLDOWN_SECONDS:
                continue
            last_activity_sound = now
            if event_kind == "thinking":
                comms.play_sound(config.THINKING_SOUND, config.THINKING_VOLUME)
            else:
                comms.play_sound(config.ACTIVITY_SOUND, config.ACTIVITY_VOLUME)
