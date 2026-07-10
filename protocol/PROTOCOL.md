# ActionHub Protocol

## Transport

Cloudflare Worker + Durable Object at `relay.babelbase.com`. One Durable Object per `room`;
everything uses room `hub`. Connections declare `role` (`phone` or `mac`) via query params.
The relay broadcasts each message to all sockets of the opposite role in the same room.
It answers a literal `ping` with `pong` and understands nothing else.

## Audio ownership

The hub owns one state machine (buffer, recording, pending send). Exactly one device owns
audio at a time — mic, TTS playback, and earcons all follow the owner:

- `phone` (default): push-to-talk via the phone's media buttons; phone mic streams to Scribe,
  TTS and earcons play on the phone (headphones, car audio, wherever the phone is routed).
- `mac`: always-listening VAD on the Mac mic; send by phrase or right arrow, discard by left
  arrow; TTS and earcons on the Mac. No push-to-talk on the Mac.

Ownership follows deliberate input: any media command from the phone takes audio for the
phone (so a button press mid-walk both takes over and starts recording); `v` on the hub
keyboard toggles between mac and phone. Nothing is inferred from presence or location.

## Messages

Phone → hub:

- `{"type": "hello", "device": "<name>"}` — on connect
- `{"type": "presence"}` — every 10s; keepalive and presence dot, nothing else
- `{"type": "command", "command": "nextTrackCommand" | "previousTrackCommand" | ...}` — media buttons, exact MPRemoteCommand names
- `{"type": "utterance", "kind": "partial" | "committed", "text": "..."}` — on-phone Scribe output
- `{"type": "playback", "active": true | false}` — phone-side TTS playback state

Hub → phone:

- `{"type": "state", "recording": bool, "pending_send": bool, "audio": "phone" | "mac"}` — after
  every state change and on connect; the phone streams real mic audio only while it owns audio
  and `recording` is true, and shuts its Scribe connection down entirely while the Mac owns audio
- `{"type": "sound", "name": "click" | "sent" | "delivered" | "record" | "stop" | "tick" | "think" | "response"}` — earcons; phone plays its bundled copy, unknown names are ignored
- `{"type": "activity", "kind": "tool_use" | "thinking" | "response", "text": "..."}` — raw Claude session events from the transcript observer, for on-screen display
- `{"type": "speak", "text": "..."}` — phone fetches TTS from ElevenLabs and plays it
- `{"type": "stop_playback"}` — abort phone-side TTS immediately
- `{"type": "commit"}` — force a Scribe commit (drain before send)

## Envelope layer (milestone 2, draft)

Ported from ActionHub legacy iOS (libsodium):

- Every device generates an Ed25519 identity keypair; private keys live in the platform keystore
  (Secure Enclave wrapped on iOS, StrongBox/Keystore on Android, Keychain on macOS).
- Pairing: devices exchange Ed25519 public keys via QR scan in person. Each peer record carries a
  role: `controller` (phone) or `viewer` (Daylight). The hub enforces roles, never the client.
- Wire format: `sealed_box(recipient_x25519, json({version, sender_public_key, signature, payload}))`
  where `signature = ed25519_sign(sender, payload)` and payload is the plaintext JSON above.
- Receivers drop messages from unknown senders before parsing the payload.
- The relay token remains as a spam guard only; confidentiality and authenticity come from the
  envelope. Replay protection: monotonic counter per sender inside the payload, receivers reject
  stale counters.

## Escalation (milestone 5, draft)

Privileged actions from viewer devices require a fresh FIDO2 assertion from a YubiKey Bio
(fingerprint UV) over USB. The hub issues a challenge, the viewer returns the assertion, the hub
verifies against the credential registered at pairing time.
