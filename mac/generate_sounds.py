import json
import os
import urllib.request

SOUND_PROMPTS = {
    "click": ("one single soft fingertip tap on warm wood, muted, round, gentle, exactly one tap only followed by silence, no reverb, no repetition", 0.5),
    "tick": ("one single tiny felt-tipped tap, extremely soft and muted, warm, barely there, exactly one tap only followed by silence", 0.5),
    "think": ("one single soft warm bubble pop, underwater, gentle, muted, round, exactly one pop only followed by silence", 0.5),
    "sent": ("a soft warm airy whoosh, like a feather brushed over silk, smooth, gentle, fading out naturally, pastel and calm", 0.7),
    "delivered": ("two gentle rising marimba notes played with soft felt mallets, warm, pastel, smooth, intimate, quiet room", 0.8),
    "response": ("a warm gentle three note marimba phrase, soft felt mallets, cozy, rounded, smooth, calm and pleasant, quiet room", 1.2),
    "record": ("a single clear warm xylophone note, bright but soft attack, short, unmistakable, exactly one note only followed by silence", 0.6),
    "stop": ("a single soft damped thud, like a felt mallet gently stopping a vibrating marimba bar, muted, warm, short, one thud only followed by silence", 0.5),
}

SOUNDS_DIRECTORY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sounds")


def generate_sound(prompt, duration_seconds):
    request = urllib.request.Request(
        "https://api.elevenlabs.io/v1/sound-generation",
        data=json.dumps({
            "text": prompt,
            "duration_seconds": duration_seconds,
            "prompt_influence": 0.85,
        }).encode(),
        headers={
            "xi-api-key": os.environ["ELEVENLABS_API_KEY"],
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request) as response:
        return response.read()


def generate_all_sounds():
    os.makedirs(SOUNDS_DIRECTORY, exist_ok=True)
    for sound_name, (prompt, duration_seconds) in SOUND_PROMPTS.items():
        sound_path = os.path.join(SOUNDS_DIRECTORY, f"{sound_name}.mp3")
        sound_audio = generate_sound(prompt, duration_seconds)
        with open(sound_path, "wb") as sound_file:
            sound_file.write(sound_audio)
        print(f"{sound_path} ({len(sound_audio)} bytes)")


if __name__ == "__main__":
    generate_all_sounds()
