import os

MICROPHONE_NAME = os.environ.get("DICTATE_MICROPHONE", "MacBook Air Microphone")
CANDIDATE_SAMPLE_RATES = (16000, 24000, 44100, 48000)

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
CHALLENGE_LIFETIME_SECONDS = 120


def build_websocket_url(sample_rate):
    return (
        "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
        "?model_id=scribe_v2_realtime"
        f"&audio_format=pcm_{sample_rate}"
        "&commit_strategy=vad"
        "&vad_silence_threshold_secs=1.0"
    )
