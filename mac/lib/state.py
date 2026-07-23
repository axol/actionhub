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
pending_challenges = {}
