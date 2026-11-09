# Native scanning milestone — November 9, 2026

The owner confirmed that build 2 installed and their existing TURC account signed in successfully. Version 0.2.0 now adds native AVFoundation camera QR scanning and Core NFC NDEF scanning/writing for NTAG215 stickers, backed by the same Supabase roster.

## Delivered source

- Full-screen native QR camera with material feedback, sounds/haptics on confirmed acceptance, and automatic camera/sleep cleanup when closed or backgrounded.
- Native NFC reader sheet; camera pauses while NFC is active. NFC sessions can read multiple stickers but must be restarted after iOS ends the session.
- Admin QR generation/sharing and NFC write/read verification. No student details in tag payload, no irreversible tag locking. The same opaque credential drives QR and NFC.
- Admin measured course distance and cooldown. No fabricated distance. Server-created daily session; captured lap distances; today/year/lifetime-at-school totals.
- Live server authorization, cross-device cooldown protected by a row lock, operator-scoped idempotence, token replacement/revocation, and no direct client lap writes.
- Lost-response retry keeps its original event ID; online confirmation is required. This is not a durable offline queue.

Migration `20261109221649_turc_native_scanning` is applied to the existing hosted project. All 26 scanning SQL checks, 36 foundation checks, and 21 import checks passed and rolled back. Private-table RLS/no-policy notices are intentional; no new actionable security finding was reported.

## Device checks still required

- [ ] Sign and install the new IPA while preserving the existing bundle/signing identity as supported by the sideloading method.
- [ ] Allow camera access, scan a generated QR, and see a server-confirmed lap and runner totals.
- [ ] Keep one QR in view: detection debounce must not repeatedly submit it; present different runners rapidly.
- [ ] Verify NFC entitlement support. If missing, confirm the scanner reports the limitation and QR still works.
- [ ] Write/read an NTAG215 through the selected sleeve; scan it and its printed QR against the same runner.
- [ ] Confirm too-soon scans from two devices do not both count.
- [ ] Replace a badge and confirm old QR/NFC stop working while historical totals remain.
- [ ] Background or close scanner and verify camera/idle timer cleanup.
- [ ] Simulate a lost response and retry the original event without double credit.

Twenty-minute field operation, tag placement, simultaneous camera/NFC operation, offline reconciliation, schedule warnings, corrections, milestones, and actual-size badge sheet printing are not declared complete by this milestone.
