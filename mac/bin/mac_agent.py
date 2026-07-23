#!/usr/bin/env python3
import asyncio
import os
import signal
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

import capture
import claude_session
import control
import phone_link
import speech
import status_bar


async def main():
    api_key = os.environ["ELEVENLABS_API_KEY"]
    event_loop = asyncio.get_running_loop()
    message_buffer = []
    microphone_state = {"muted": False}
    voice_activity_state = {"last_spoke": 0.0}
    speech_state = {"last_text": None}
    playback_state = {"active": False, "stop_requested": False}
    recording_state = {"recording": False, "pending_send": False}

    capture.configure(api_key, microphone_state, voice_activity_state, message_buffer, recording_state)
    capture.prepare_microphone()
    status_bar.setup_status_bar(message_buffer, recording_state, playback_state)
    event_loop.add_signal_handler(signal.SIGWINCH, status_bar.handle_terminal_resize)
    control.setup_keyboard(event_loop, message_buffer, playback_state, recording_state)
    print("[audio: phone] press v to switch to mac listening", file=sys.stderr)
    await asyncio.gather(
        speech.consume_speak_requests(microphone_state, voice_activity_state, speech_state, playback_state, recording_state, message_buffer),
        claude_session.observe_transcript(),
        phone_link.consume_phone_events(voice_activity_state, playback_state, recording_state),
        status_bar.refresh_status_bar(),
    )


if __name__ == "__main__":
    asyncio.run(main())
