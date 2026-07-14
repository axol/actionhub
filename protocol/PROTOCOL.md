# ActionHub Protocol

## Terms

- **relay** — the Cloudflare Worker + Durable Object at `relay.babelbase.com`. A dumb pipe: it
  forwards messages between roles in a room, decides nothing, sees (eventually) only ciphertext.
- **bridge** — `bridge/dictate.py` on the Mac. Delivers messages into Claude session inboxes,
  observes transcripts, plays Mac audio, runs the Mac VAD engine.
- **phone** — the iOS app. Owns its own capture state machine, buffer, presets, and sounds.
- **viewer** — the Daylight tablet (later milestone).

## Transport

One Durable Object per `room`; everything uses room `actionhub`. Connections declare `role`
(`phone` or `mac`) via query params. The relay broadcasts each message to all sockets of the
opposite role in the same room. It answers a literal `ping` with `pong` and understands nothing
else.

## Audio ownership

Exactly one device owns audio at a time — mic, TTS playback, and earcons follow the owner.
Ownership follows deliberate input: any button on the phone takes audio for the phone; `v` on the
bridge keyboard toggles between mac and phone. Nothing is inferred from presence or location.

State follows the audio owner. While the phone owns audio it runs its own state machine locally —
recording, transcript segments, drain-and-send, discard — and merely informs the bridge. No
round-trip is required to start or stop capture, so the phone works even while the bridge is
briefly unreachable (except for actual delivery). While the Mac owns audio, the bridge runs the
equivalent state machine (VAD listening, buffer, send by phrase or right arrow).

Phone modes are phone-local: `ptt` (tap to record, tap to send) and `vad` (always listening while
the phone owns audio; the send button commits and sends, discard clears the buffer but keeps
listening). Presets, earcon remapping, generated sounds, button visibility, and the send phrase
never reach the bridge.

## Messages

Phone → bridge:

- `{"type": "hello", "device": "<name>"}` — on connect
- `{"type": "presence"}` — every 10s; keepalive and presence dot, nothing else
- `{"type": "take_audio"}` — deliberate input while the Mac owned audio; the bridge flips the
  owner to phone and confirms with `state`
- `{"type": "status", "recording": bool, "sending": bool, "buffer": <n>, "mode": "ptt" | "vad"}` —
  after every local state change; display mirror and TTS gating only, the bridge never interprets
  buttons
- `{"type": "utterance", "kind": "partial" | "committed", "text": "..."}` — on-phone Scribe output,
  display mirror only
- `{"type": "message", "text": "..."}` — the assembled message (surviving segments joined) at send
  time; the bridge delivers it to the Claude session verbatim
- `{"type": "playback", "active": true | false}` — phone-side TTS playback state

Bridge → phone:

- `{"type": "state", "audio": "phone" | "mac"}` — on connect and every ownership change; on
  gaining audio the phone applies its mode (vad starts listening immediately), on losing it the
  phone stops capture and shuts its Scribe connection down
- `{"type": "sound", "name": "click" | "sent" | "delivered" | "record" | "stop" | "tick" | "think" | "response" | "failed"}` —
  bridge-triggered earcons (delivery outcomes, Claude activity); the phone resolves each through
  the active preset's sound map, so any event can be remapped or silenced. Capture earcons
  (record/stop/click) are played by the phone itself.
- `{"type": "activity", "kind": "tool_use" | "thinking" | "response" | "received" | "error", "text": "..."}` — raw Claude session events from the transcript observer, plus delivery outcomes, for on-screen display
- `{"type": "speak", "text": "..."}` — phone fetches TTS from ElevenLabs and plays it
- `{"type": "stop_playback"}` — abort phone-side TTS immediately

Delivery acknowledgment: `sent` fires when the bridge writes the message to the session inbox;
`delivered` (ka-ching) fires only when the message text is observed in the target session's
transcript — proof of injection. If nothing appears within 10s the bridge plays `failed` and sends
an `error` activity; a late injection still confirms with `delivered` afterwards.

## Transcript buffer

The transcript buffer lives with the audio owner. While the Mac owns audio, the bridge accumulates
committed utterances. While the phone owns audio, the phone holds a list of segments (one per
Scribe commit); each segment can be dropped on screen before sending, partials render live, and
only the assembled surviving text crosses the wire as `message`. The bridge mirrors the phone
buffer for display (partials + `status` counts) but never owns it.

## Envelope layer (milestone 2, draft)

Ported from ActionHub legacy iOS (libsodium):

- Every device generates an Ed25519 identity keypair; private keys live in the platform keystore
  (Secure Enclave wrapped on iOS, StrongBox/Keystore on Android, Keychain on macOS).
- Pairing: devices exchange Ed25519 public keys via QR scan in person. Each peer record carries a
  role: `controller` (phone) or `viewer` (Daylight). The bridge enforces roles, never the client.
- Wire format: `sealed_box(recipient_x25519, json({version, sender_public_key, signature, payload}))`
  where `signature = ed25519_sign(sender, payload)` and payload is the plaintext JSON above.
- Receivers drop messages from unknown senders before parsing the payload.
- The relay token remains as a spam guard only; confidentiality and authenticity come from the
  envelope. Replay protection: monotonic counter per sender inside the payload, receivers reject
  stale counters.

## Escalation (milestone 5, draft)

Privileged actions from viewer devices require a fresh FIDO2 assertion from a YubiKey Bio
(fingerprint UV) over USB. The bridge issues a challenge, the viewer returns the assertion, the
bridge verifies against the credential registered at pairing time.
