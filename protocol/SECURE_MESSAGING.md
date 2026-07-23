# Secure Messaging

The message channel between an agent (sender) and the phone (responder). Adopted from the
pecunia `secure_messaging` plugin; wire-compatible with its Ruby structs and with the
`actionhub.rb` sender CLI. The relay stores sealed blobs and understands nothing.

## Identities and pairing

- Each peer owns one Ed25519 keypair. X25519 encryption keys are derived from it
  (libsodium `crypto_sign_ed25519_*_to_curve25519`).
- On the phone the Ed25519 secret lives in the iOS Keychain behind
  `kSecAccessControlBiometryCurrentSet` — unusable without a live biometric match,
  self-invalidating when enrolled biometrics change. No backup, no export. Lost device
  means fresh enrollment and re-pairing.
- Pairing is a public-key exchange, QR or paste. The key travels as its raw Base64 string;
  the phone also accepts the pecunia QR dialect `{"label", "public_key"}` when pasted.

## Channel

`channel_id = HMAC-SHA256(X25519(my_private, peer_public), "canvas")` (hex).

Both peers derive the same id; nobody registers anything. The channel id is the only
credential for reading a channel's blob list — an unguessable bearer derived from the
pair's shared secret. Blobs stay sealed regardless.

## Envelope

Every message on the wire, both directions:

```
Base64(SealedBox(recipient_x25519_public, JSON({
  "version": 1,
  "signature": Base64(Ed25519_sign(sender, payload)),
  "sender_public_key": Base64(sender Ed25519 public),
  "payload": "<payload JSON as a string>"
})))
```

SealedBox is libsodium `crypto_box_seal` (ephemeral X25519 + XSalsa20-Poly1305).
Receivers decrypt, check `sender_public_key` equals the expected peer, then verify the
signature over the exact `payload` string before parsing it.

## Request payload (agent → phone)

```json
{
  "envelope_type": "request",
  "type": "action",
  "nonce": "<random hex>",
  "title": "…",
  "body": { "content_type": "html" | "md" | "txt", "content": "…" },
  "buttons": [ { "label": "Approve", "value": "approve" }, … ]
}
```

`type: "message"` with no `buttons` is a display-only card. The `nonce` makes otherwise
identical payloads produce distinct message ids. Extra fields (`message`, `object`,
`context` from the pecunia dialect) are allowed; the phone renders what it knows and
echoes everything back untouched.

## Response payload (phone → agent)

```json
{
  "envelope_type": "response",
  "type": "action_response",
  "request_id": "<id of the request>",
  "request_payload": { …exact request payload as received… },
  "response": { "button": { "label": "Approve", "value": "approve" } },
  "timestamp": 1702500000000,
  "utterances": ["optional free-text note"]
}
```

The phone builds the response JSON by splicing the *raw request payload bytes* — exactly
as they arrived inside the request envelope — into the `request_payload` field. It never
re-serializes the request. This is what makes the answer non-repudiable: the signature
covers the response payload string, which physically contains the question bytes.

## Canonical JSON and message ids

`canonical_json(value)`: keys sorted alphabetically at every level, no whitespace,
UTF-8, minimal string escaping (`"`, `\`, control characters only — no `\/`), integers
without decimal point. Identical to Ruby `JSON.generate(value, sort_keys: true)`.

- `id = HMAC-SHA256(sender_hmac_key, canonical_json(request_payload))` (hex)
- `deletion_key = HMAC-SHA256(sender_hmac_key, "delete_" + id)` (hex)

Only the sender computes canonical JSON; `sender_hmac_key` never leaves the sender. The
sender validates an answer by recomputing the HMAC over `canonical_json(request_payload)`
from the response and comparing it to `request_id` — proof the responder saw the exact
question. Validation order: sender key match → signature → `envelope_type` →
required fields → `request_id` match → `request_payload.envelope_type` → HMAC.

## Biometric signature (optional, enforced by key presence)

A response may carry a second, hardware-bound signature proving a live biometric
ceremony approved this exact answer. The ActionHub envelope and payload format stay
identical; one field is added inside the response payload:

```json
{ "...": "response payload as above", "biometric_signature": "<Base64 DER ECDSA>" }
```

- The phone holds a P-256 key generated inside the Secure Enclave
  (`kSecAttrTokenIDSecureEnclave`, `.privateKeyUsage + .biometryCurrentSet`). The private
  key never exists in memory; every signature is an enclave operation gated by Face ID.
- Signed message (UTF-8, exact bytes):
  `"actionhub-biometric-v1\n" + request_id + "\n" + button_value + "\n" + timestamp + "\n" + note`
  with `note = ""` when absent. Content binding is transitive and canonicalization-free:
  the signature binds `request_id`, and the verifier's existing HMAC check binds
  `request_id` to the exact question bytes.
- The signature is created before the peer signature, so the ActionHub envelope
  attests and encrypts the biometric proof itself.
- Public key travels as Base64 of the X9.63 uncompressed point (65 bytes).

Enforcement is fail-closed and declared per peer in
`$MESSAGE_RELAY_BASE_PATH/peer_configs/<peer_name>.json`:

- `{"biometric_signature": "required", "biometric_public_key": "<Base64 X9.63>"}` —
  verify, reject a missing or invalid signature
- `{"biometric_signature": "none"}` — deliberately exempt, the only unverified path
- Config file missing, field missing, unknown value, or `required` without a key →
  reject the reply. Nothing is auto-created; the error prints the template.

The `.pub` peer files stay pure public keys. Turning enforcement off means writing
the literal string `"none"` into a config — every accident, deletion, or typo lands
on reject.

## Relay API

Served by `relay/` (`MessageStore` Durable Object) at `https://actionhub.app`.
No token; the channel id is the bearer.

| Route | Body | Returns |
|---|---|---|
| `POST /messages` | `{id, channel, request_blob, deletion_key}` | `201 {id}`, `409` if id exists |
| `GET /messages?channel=<id>` | — | `[{id, request_blob, response_blob, created_at}]` oldest first |
| `GET /messages/<id>` | — | `{id, request_blob, response_blob, created_at}` or `404` |
| `PATCH /messages/<id>` | `{response_blob}` | `200`, `409` if already responded |
| `GET /messages/<id>/poll` | — | `200 {response_blob}` or `204` after ~50s |
| `GET /channels/<id>/poll` | — | unanswered messages oldest first, or `204` after ~50s |
| `DELETE /messages/<id>` | `{deletion_key}` | `200`, `403` wrong key, `404` gone |

`created_at` is relay-assigned epoch milliseconds. A message accepts exactly one
response; answers are immutable once posted.
