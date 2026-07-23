import asyncio
import atexit
import shutil
import sys
import time

import config
import state


def render_status_bar():
    if not state.status_bar_state["enabled"]:
        return
    recording_state = state.status_bar_state["recording_state"]
    playback_state = state.status_bar_state["playback_state"]
    if state.audio_state["owner"] == "mac":
        currently_sending = recording_state["pending_send"]
        currently_recording = recording_state["recording"]
    else:
        currently_sending = state.phone_state["sending"]
        currently_recording = state.phone_state["recording"]
    if currently_sending:
        activity = "sending"
    elif currently_recording:
        if state.audio_state["owner"] == "mac" or state.phone_state["mode"] == "vad":
            activity = "listening"
        else:
            activity = "RECORDING"
    elif playback_state["active"]:
        activity = "speaking"
    else:
        activity = "idle"
    scribe_marker = "●" if state.status_bar_state["scribe"] else "○"
    relay_marker = "●" if state.status_bar_state["relay"] else "○"
    phone_present = time.monotonic() - state.status_bar_state["phone_last_seen"] < config.PHONE_PRESENCE_TIMEOUT_SECONDS
    phone_marker = "●" if phone_present else "○"
    session_pid = state.status_bar_state["session_pid"]
    claude_marker = str(session_pid) if session_pid else "○"
    if state.audio_state["owner"] == "mac":
        buffer_count = len(state.status_bar_state["message_buffer"])
    else:
        buffer_count = state.phone_state["buffer_count"]
    segments = [
        f"audio {state.audio_state['owner']} {activity}",
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
    first_row = rows - config.STATUS_BAR_ROWS + 1
    output = f"\0337\033[{first_row};1H\033[7m{status_line.ljust(columns)}\033[0m"
    for row_offset in range(1, config.STATUS_BAR_ROWS):
        partial_line = partial_lines[row_offset - 1] if row_offset - 1 < len(partial_lines) else ""
        output += f"\033[{first_row + row_offset};1H\033[2m{partial_line.ljust(columns)}\033[0m"
    sys.stderr.write(output + "\0338")
    sys.stderr.flush()


def wrap_partial_lines(columns):
    if not state.status_bar_state["partial"]:
        return []
    partial_text = f"… {state.status_bar_state['partial']}"
    chunk_width = max(columns - 1, 10)
    chunks = [partial_text[start:start + chunk_width] for start in range(0, len(partial_text), chunk_width)]
    return chunks[-(config.STATUS_BAR_ROWS - 1):]


def apply_scroll_region():
    columns, rows = shutil.get_terminal_size()
    top_of_bar = rows - config.STATUS_BAR_ROWS + 1
    clear_bar_rows = "".join(f"\033[{row};1H\033[K" for row in range(top_of_bar, rows + 1))
    sys.stderr.write(f"{clear_bar_rows}\033[1;{top_of_bar - 1}r\033[{top_of_bar - 1};1H")
    sys.stderr.flush()


def teardown_status_bar():
    if not state.status_bar_state["enabled"]:
        return
    state.status_bar_state["enabled"] = False
    columns, rows = shutil.get_terminal_size()
    top_of_bar = rows - config.STATUS_BAR_ROWS + 1
    clear_bar_rows = "".join(f"\033[{row};1H\033[K" for row in range(top_of_bar, rows + 1))
    sys.stderr.write(f"\033[r{clear_bar_rows}")
    sys.stderr.flush()


def setup_status_bar(message_buffer, recording_state, playback_state):
    if not sys.stderr.isatty():
        return
    state.status_bar_state["message_buffer"] = message_buffer
    state.status_bar_state["recording_state"] = recording_state
    state.status_bar_state["playback_state"] = playback_state
    state.status_bar_state["enabled"] = True
    apply_scroll_region()
    atexit.register(teardown_status_bar)
    render_status_bar()


def handle_terminal_resize():
    if not state.status_bar_state["enabled"]:
        return
    apply_scroll_region()
    render_status_bar()


async def refresh_status_bar():
    if not state.status_bar_state["enabled"]:
        return
    import claude_session
    last_session_check = 0.0
    while True:
        now = time.monotonic()
        if now - last_session_check >= config.SESSION_CHECK_INTERVAL_SECONDS:
            last_session_check = now
            session_entry = claude_session.find_live_voice_session()
            state.status_bar_state["session_pid"] = session_entry["claudeProcessId"] if session_entry else None
        render_status_bar()
        await asyncio.sleep(config.STATUS_REFRESH_SECONDS)


def show_live_partial(text):
    if state.status_bar_state["enabled"]:
        state.status_bar_state["partial"] = text.strip()
        render_status_bar()
        return
    terminal_width = shutil.get_terminal_size().columns
    line = f"… {text}"
    if len(line) >= terminal_width:
        line = "…" + line[-(terminal_width - 2):]
    print(f"\r\033[K{line}", end="", file=sys.stderr, flush=True)


def clear_live_partial():
    if state.status_bar_state["enabled"]:
        state.status_bar_state["partial"] = ""
        render_status_bar()
        return
    print("\r\033[K", end="", file=sys.stderr, flush=True)
