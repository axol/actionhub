# Actionvoice — Architecture Spec

## Thesis

WhatsApp where the contacts are your agent sessions. The phone records,
plays, and renders cards. Agents think. The relay is a blind mailbox.
Every byte that crosses the network is sealed.

## Names

- **actionvoice** — the iOS app. Bundle id `li.taurusag.actionvoice`.
- **actionhub** — the server side: Cloudflare relay, protocol, and the
  cross-language fixtures. This repo.
- **macking** — the mac side: bridge process, decoder, panel. Lives in
  the `macking` repo.

## Vision (normative)

1. Actionvoice is WhatsApp where the contacts are agent sessions.
2. The phone is minimal: it records, plays, and renders cards. It makes
   one decision — which conversation you speak in. It holds its own
   identity keys (biometry-gated) and no third-party keys.
3. Choosing the conversation is choosing the route.
4. Every byte on the network is sealed. The relay is a blind mailbox.
5. Intelligence lives in agents on the Mac: a coordinator as the default
   contact, plus per-session agents.
6. Recording always works, including offline. Transcripts catch up when
   connectivity does.
7. Speed is a feature: upload while you speak, decode while audio
   arrives, wait at stop is near constant.

## Layering

```
channel  — one per device pair; the crypto boundary
thread   — one per conversation (session); multiplexed inside the channel
message  — one sealed envelope of parts
chunk    — one message fragment with an index; the streaming unit
```

The `thread_id` travels inside the sealed envelope. The relay never sees
thread structure.

## Relay (actionhub)

- One SQLite-backed Durable Object per channel: `idFromName(channel_id)`.
- Append-only message/chunk log with sequence numbers. Long-polls park in
  memory and wake on write. One long-poll per device covers all threads.
- 7-day TTL, enforced by the DO's own `alarm()`. The relay is a mailbox,
  never the archive.
- Reads: `channel_id` is the bearer. Writes: `X-Write-Key` header =
  `hex HMAC-SHA256(shared_secret, "write")`; the DO stores its hash on
  first write and compares thereafter. No credentials in URLs, ever.
- Deleted: `RelayHub`, `RELAY_TOKEN`, the singleton `MessageStore`, and
  the whole plaintext WebSocket plane.

## Crypto

- Identity: one Ed25519 keypair per device in a biometry-gated Keychain
  item; X25519 derived from it; `channel_id = hex HMAC-SHA256(shared,
  "canvas")`. Unchanged from `protocol/SECURE_MESSAGING.md`.
- Streams: `crypto_secretstream_xchacha20poly1305` per take; the stream
  key is sealed to the peer with `crypto_box_seal`.
- Button answers carry the Secure Enclave P-256 biometric signature,
  sealed inside the envelope. Unchanged.
- The Ruby fixtures (rbnacl) are the interop oracle. Every protocol
  change lands in the fixtures first, then in Swift.

## Messages

- Parts, any combination: `voice` (AAC chunks) · `text` · `html` ·
  `buttons`. Replies carry `in_reply_to` plus any parts.
- `html` starts with `<summary>`/`<details>`. It is generated
  deterministically by tooling (branch files, PR diffs), never by an
  LLM. Rendered in a WKWebView with JavaScript off.
- A question card is `{voice, html, buttons}` — a combination, not a
  separate plane.
- Downstream voice plays as chunks arrive. Upstream audio uploads while
  you speak. These are the only two streaming cases.

## Phone (actionvoice)

- UI: chat list → thread. Composer: hold to talk, release sends;
  swipe up locks for long rambles; slide left cancels. The spoken send
  phrase works in locked mode.
- iOS 26 baseline. AAC capture. Offline: on-device transcription
  (SpeechAnalyzer) and automatic background upload when connectivity
  returns.
- The phone keeps its sealed local copy until the Mac acknowledges
  receipt, and after that until the user deletes it.
- Settings has an identity reset action: delete both keys, re-enroll,
  re-pair. This is the recovery path when biometrics change.
- Pairing is paste-only with a fingerprint eyeball check.
- Ship release builds with speed optimization. Capture, crypto, and
  network run off the MainActor.
- APNs sends a content-free wake push when a message arrives.

## Mac (macking)

- The bridge is a long-running Ruby process (`bin/runner` pattern)
  inside the panel Rails app. Four verbs:
  1. Long-poll the channel, unseal, decode audio.
  2. Hand the message to the thread's agent.
  3. Seal the agent's reply; TTS the voice part (ElevenLabs).
  4. Archive everything into the panel.
- Decode paths: parakeet streaming (`transcribe_stream`) for the live
  transcript; whisper batch with glossary prompt for the archival
  re-decode. The WER harness arbitrates quality between them.
- Decoder placement is config, two slots: `live` (localhost default)
  and `batch` (localhost or ultra).
- The coordinator agent is the default contact. It consumes rambles and
  adopts unknown threads. Sessions are ephemeral; threads persist.

## Topology

- Hub-and-spoke: pairwise channels only, the Mac is the hub. No group
  crypto, ever.
- DC1 joins later as a third pair: Ed25519 transport key wrapped under
  the YubiKey `hmac-secret` extension, FIDO2 assertion as attestation.
  Out of v1.

## Rules

- No third-party API keys on the phone.
- Nothing secret in URLs. Headers only.
- The relay stores only sealed bytes and hex ids.
- HTML details are deterministic, never LLM-generated.
- Protocol changes land in the Ruby fixtures before any client code.

## Roadmap

1. Rename and restructure the repos; this spec reviewed first.
2. Relay v2: per-channel DO, write key, chunk log, TTL. Fixtures first.
3. Decoder streaming mode: parakeet `transcribe_stream` in `server.py`,
   WER-validated against batch.
4. Mac bridge v1: poll, unseal, decode, coordinator hand-off, seal
   reply, TTS.
5. Actionvoice iOS v1: identity and pairing, chat list and thread, PTT
   composer, streamed playback, offline capture.
6. APNs and panel archive integration.
7. Later: DC1 pair. If ever needed: per-thread subkeys, R2 blob offload,
   D1 as a write-through index.

## Superseded

- `protocol/PROTOCOL.md` — superseded entirely (plaintext plane).
- `protocol/SECURE_MESSAGING.md` — identity, envelope, and biometric
  sections remain normative; the `MessageStore` HTTP API is superseded
  by the per-channel DO.

## Open

- The coordinator runtime (grunt-style daemon vs headless session).
  Blocks phase 4, nothing earlier.
