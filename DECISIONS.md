# Actionvoice — Decision Log

Each entry: the decision, the reasoning that settled it, what was
rejected. Companion to `SPEC.md`. Newest thinking wins; entries are
amended, not appended twice.

## 1. Full restructure, not a patch

The first prototype was vibe-coded (partly dictated while driving,
through the very voice mode it built). It shipped a plaintext voice
plane, a shared relay token in URLs, and an unauthenticated PATCH.
Simon: "better build this one time well, than 100 times bad." The old
code is evidence, not a reference.

Kept from it anyway: the `Messaging/` crypto with Ruby fixtures, the
`channels/` MCP design, atomic file handoffs — the parts that were
designed, not improvised.

## 2. Product shape: WhatsApp where contacts are sessions

The agent reaching out — "here is the situation, what do you think" —
is the core loop, not remote control of one session. Multi-session is
designed in from day one because Simon talks to multiple agents.
Routing happens by choosing the conversation you speak in — proven
UI/UX, zero routing metadata.

Rejected: sink headers on takes (phone-side routing — the phone must
stay minimal); a single coordinator pipe (complicates routing);
two-tab inbox/voice split (an artifact of the old two transports).

## 3. Relay: one Durable Object per channel

The old relay put every user's messages in ONE global DO
(`idFromName('messages')`) — one storage limit, one region, one queue.
D1 was evaluated at Simon's request and rejected: it recreates the same
singleton shape (one SQLite for everyone) and cannot wake a waiting
subscriber — a database cannot call you, so delivery degrades to
polling. A per-channel DO gives instant wake (parked long-polls resolve
on write), per-channel isolation, and its own `alarm()` GC.

Exit hatch: D1 bolts on later as a write-through index if cross-channel
queries ever become real. Not before.

## 4. Threads multiplexed inside one pair channel

Evaluated in depth at Simon's request. The forcing function: relay
channels are unlinkable by design, so per-thread channels cannot be
discovered by the other side — any such design silently needs a pair
control channel anyway. The multiplexed design wins on: one long-poll
for all threads (battery), one sequence cursor (trivial resume), and
thread structure hidden inside the sealed envelope (the relay sees
less, not more). Phone-created conversations are the cheapest
operation: an unknown `thread_id` arriving IS the creation event.

Rejected: channel-per-thread (fails discovery); control+data hybrid
(pays three phone-side costs to relieve a load that does not exist at
personal scale); per-thread subkeys (no security gain while both
devices hold the pair secret — noted as a future extension point).

## 5. Write key kills response poisoning

The old relay let anyone with a channel_id list all message ids and
PATCH garbage into any response — first write wins forever (409). The
fix: `write_key = HMAC(shared, "write")`, derived on both clients,
presented as a header, hash-stored by the relay. A leaked channel_id
now grants read-only. All credentials move out of URLs because
`observability: true` was logging them.

## 6. Streaming is latency hiding, not streaming ASR

Verified in macking: the recorder tails the growing WAV up a socket
while recording; the server decodes ONCE at finalize. The instant feel
is upload-during-speech, not incremental transcription. Actionvoice
extends the same trick end-to-end: phone → relay → mac all overlap
with speech; at stop only the final decode remains.

Rejected: live partials to the phone (Simon: not needed); upstream
streaming for a live consumer that does not exist.

## 7. Two decode paths, both models

Simon: "we also use parakeet — why not both?" Parakeet streaming
(`transcribe_stream`, verified in the pinned parakeet-mlx 0.4.1) serves
the live path with near-constant flush. Whisper batch with glossary
prompt biasing serves the archival re-decode. The macking panel's
schema (decodings = recording × decoder × config, WER vs gold
references) was built for exactly this comparison — the choice is
measured, not vibed.

## 8. Prefeed the decoder; run it locally

Prefeeding (decode while audio arrives) makes the wait at stop
near-constant regardless of take length — the win is specifically the
hour-long ramble. It also drops the compute requirement to real-time
RTF, which any M-series meets. Simon: then it need not run on ultra.
Placement is config with two slots: `live` (localhost) and `batch`
(localhost or ultra for bulk re-decodes). Ultra stops being a critical
dependency of every utterance.

## 9. Names: actionvoice / actionhub / macking

Simon: "overlaying two things on the same name isn't good — now is the
moment to make the rename, not later." Bundle ids, Keychain items, and
derivation strings are being created fresh; renaming later means
re-pairing and Keychain migration. actionvoice = phone app,
actionhub = server side (relay + protocol + fixtures), macking = mac
side.

## 10. Mac bridge: Ruby, inside the macking panel

In the new design the mac side has NO realtime audio — only HTTP
long-poll, envelope crypto, file drops, one decoder call, TTS. All
trivial in Ruby, and rbnacl is already the fixture oracle. Folding the
bridge into the panel (bin/runner long-running process) gives one repo,
one language, one Postgres, one decoder client, one review UI. Simon's
driver: "I don't want hundreds of WET shit everywhere."

Rejected: separate Python daemon (two languages, two decoder clients,
forever); panel absorbing the pipeline in-request (its sync no-jobs
design is not shaped for it); a separate actionhub mac stack (the WET
explosion).

## 11. Codec: AAC

Native hardware encoder in AVFoundation, no vendoring; ~1 MB per
10 minutes matters for hour-long offline rambles stored on the phone.
The decoder's batch endpoint accepts it by filename suffix. Rejected:
Opus (no first-party iOS encoder), raw PCM (~115 MB/hour).

## 12. Offline is a first-class path

Simon records during prolonged offline periods (planes, no coverage).
The phone transcribes locally (SpeechAnalyzer, iOS 26 baseline) and
uploads sealed takes automatically when connectivity returns. The
phone keeps its sealed copy until the Mac acknowledges receipt, and
after that until Simon deletes it — the relay TTL never governs the
phone's copy.

## 13. Performance is a requirement

The previous app was "ultra laggy." Two causes, two fixes: ship
release builds with speed optimization, and keep capture, crypto, and
network off the MainActor by construction (the old app pinned WebSocket
callbacks to the main queue).

## 14. APNs content-free push

Agent-initiated questions are the core loop; the old 15-minute
background refresh left urgent approvals unseen. The relay sends a
content-free wake push; all content stays sealed.

## 15. Identity reset action

Not a Simon requirement — an accepted fix. `.biometryCurrentSet`
permanently invalidates the key when biometrics re-enroll, and Keychain
items survive reinstall: without a reset action the app bricks with no
recovery. Settings gets delete-both-keys → re-enroll → re-pair.

## 16. DC1 stays in the vision, out of v1

Simon: the no-backlight display is superior long-run; DC1 integration
is preferred, with three devices total (phone with Face ID, DC1 with
YubiKey biometrics, Mac). Topology is hub-and-spoke pairwise channels —
no group crypto. The DC1 joins as a third pair later: Ed25519 transport
key wrapped under YubiKey hmac-secret (the keyboard project already
ships this vault), FIDO2 assertion as attestation — the same two-key
split as iOS.

## 17. HTML details are deterministic

Cards carry `<summary>`/`<details>` HTML generated by tooling from the
branch or PR — never by an LLM. Trustworthy (no hallucinated diffs),
free (no tokens), and renderable with JavaScript off.

## 18. Pairing stays paste-only

Simon: fine as is. The QR scanner proposal was dropped.
