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
- `{"type": "config", "mode": "ptt" | "vad"}` — on connect and whenever the active preset changes a
  hub-shared setting; the hub interprets button semantics per mode
- `{"type": "command", "command": "nextTrackCommand" | "previousTrackCommand" | ...}` — media buttons, exact MPRemoteCommand names
- `{"type": "utterance", "kind": "partial" | "committed", "text": "..."}` — on-phone Scribe output,
  display mirror only; the hub does not buffer these
- `{"type": "buffer", "count": <n>}` — segment count of the phone-side transcript buffer, for the
  hub status bar and speak gating
- `{"type": "message", "text": "..."}` — the assembled message (surviving segments joined) at send
  time; the hub delivers it to the Claude session verbatim
- `{"type": "playback", "active": true | false}` — phone-side TTS playback state

Hub → phone:

- `{"type": "state", "recording": bool, "pending_send": bool, "audio": "phone" | "mac"}` — after
  every state change and on connect; the phone streams real mic audio only while it owns audio
  and `recording` is true, and shuts its Scribe connection down entirely while the Mac owns audio
- `{"type": "sound", "name": "click" | "sent" | "delivered" | "record" | "stop" | "tick" | "think" | "response" | "failed"}` — earcons; phone plays its bundled copy, unknown names are ignored
- `{"type": "activity", "kind": "tool_use" | "thinking" | "response" | "received" | "error", "text": "..."}` — raw Claude session events from the transcript observer, plus delivery outcomes, for on-screen display

Delivery acknowledgment: `sent` fires when the hub writes the message to the session inbox;
`delivered` (ka-ching) fires only when the message text is observed in the target session's
transcript — proof of injection. If nothing appears within 10s the hub plays `failed` and sends
an `error` activity; a late injection still confirms with `delivered` afterwards.
- `{"type": "speak", "text": "..."}` — phone fetches TTS from ElevenLabs and plays it
- `{"type": "stop_playback"}` — abort phone-side TTS immediately
- `{"type": "commit"}` — start the send drain: phone forces a Scribe commit, waits for the final
  committed segment (2.5s cap), then answers with `message`
- `{"type": "discard"}` — clear the phone-side transcript buffer

## Transcript buffer

The transcript buffer lives with the audio owner. While the Mac owns audio, the hub accumulates
committed utterances exactly as before. While the phone owns audio, the phone holds a list of
segments (one per Scribe commit); each segment can be dropped on screen before sending, partials
render live, and only the assembled surviving text crosses the wire as `message`. The hub mirrors
the phone buffer for display (partials + `buffer` counts) but never owns it.

Phone modes: `ptt` (recording toggled by buttons) and `vad` (always listening while the phone owns
audio; the send button commits and sends, discard clears the buffer but keeps listening). Earcons,
sound remapping, presets, button visibility, and the send phrase are phone-local settings and never
reach the hub.

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
