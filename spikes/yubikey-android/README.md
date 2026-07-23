# YubiKey Bio spike (Daylight DC1)

Throwaway app. Verifies the assumptions milestone 5 depends on, using Yubico's own SDK
(no Play Services dependency — Sol:OS may not have them):

1. The DC1 delivers USB HID devices to apps (host mode works)
2. YubiKit enumerates the YubiKey Bio over USB-C
3. A CTAP2 session opens and `getInfo` reports `bioEnroll` (fingerprint) support

Run: open this folder in Android Studio, let it sync, deploy to the DC1, plug in the key.
Every step prints to the screen; the last lines answer the three questions.

Phase 2 of the spike (only if phase 1 passes): makeCredential + getAssertion with
`uv=true` — confirms a fingerprint touch alone authorizes an assertion, no PIN prompt.
