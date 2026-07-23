# ActionHub Voice Keyboard (Daylight DC1)

Standalone system IME: dictate into any app via ElevenLabs Scribe v2 realtime, partials live,
segments reviewable and droppable, one commit button inserting the assembled text. The YubiKey
Bio gates session unlock only; signed commits (CTAP2 signature over the committed text) are a
possible later step. Fully independent of the mac daemon and the relay.

## Key handling

The ElevenLabs API key (STT + tokens scopes only, credit-capped, stored on the mac in
`../.secrets/elevenlabs-scribe-dc1`) never lives on the tablet in plaintext:

- Enrollment wraps it with AES-256-GCM under a KEK derived via the FIDO2 `hmac-secret`
  extension — recoverable only with the physical YubiKey plus enrolled fingerprint.
- Each dictation session: one touch unwraps the key in memory, mints a 15-minute single-use
  `realtime_scribe` token, zeroizes the key, and connects the websocket with the token.

## Setup

1. Deploy both the enrollment app and keyboard (one APK): `./gradlew installDebug`
2. Mac: `pbcopy < ../.secrets/elevenlabs-scribe-dc1`, send the clipboard to the DC1 via
   LocalSend, then `pbcopy < /dev/null`
3. DC1: open ActionHub Voice Keyboard, grant mic permission, paste the key, plug in the
   YubiKey, "wrap key to yubikey" (two touches: credential + wrap; clipboard is cleared after)
4. "verify: unwrap + mint token" confirms the whole chain against the live API
5. "enable keyboard in system settings", then clear the received text from LocalSend's history

## Unverified assumptions (first on-device run tells)

- `hmac-secret` present on this YubiKey Bio's firmware (CTAP2.1 makes it mandatory)
- The realtime STT websocket accepts single-use tokens via the `token` query parameter
