# ActionHub Protocol

## Transport

Cloudflare Worker + Durable Object at `relay.babelbase.com`. One Durable Object per `room`.
Connections declare `role` (`phone` or `mac`) and `room` via query params. The relay broadcasts
each message to all sockets of the opposite role in the same room. It answers `ping` with `pong`
and understands nothing else.

Rooms in use:

- `car` — legacy car remote: raw `{"command": "<MPRemoteCommandName>"}` events, phone → mac only
- `walk` — walk mode, bidirectional, message vocabulary below

## Walk mode messages (milestone 1, plaintext JSON)

Phone → hub:

- `{"type": "hello", "device": "<name>"}` — sent on connect
- `{"type": "command", "command": "nextTrackCommand" | "previousTrackCommand" | ...}` — headphone buttons
- `{"type": "utterance", "kind": "partial" | "committed", "text": "..."}` — on-phone Scribe output
- `{"type": "playback", "active": true | false}` — phone-side TTS playback state

Hub → phone:

- `{"type": "state", "recording": bool, "pending_send": bool, "vad": bool}` — after every state change and on connect; the phone streams real microphone audio only while `recording` is true, silence otherwise
- `{"type": "sound", "name": "click" | "sent" | "delivered" | "record" | "stop" | "tick" | "think" | "response"}` — earcon mirroring; phone plays its bundled copy, unknown names are ignored
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
  where `signature = ed25519_sign(sender, payload)` and payload is the milestone-1 JSON.
- Receivers drop messages from unknown senders before parsing the payload.
- The relay token remains as a spam guard only; confidentiality and authenticity come from the
  envelope. Replay protection: monotonic counter per sender inside the payload, receivers reject
  stale counters.

## Escalation (milestone 5, draft)

Privileged actions from viewer devices require a fresh FIDO2 assertion from a YubiKey Bio
(fingerprint UV) over USB. The hub issues a challenge, the viewer returns the assertion, the hub
verifies against the credential registered at pairing time.
