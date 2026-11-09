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

## Verified build 4

GitHub Actions [run 4](https://github.com/richardmeyer2003/truc-ios/actions/runs/42712437900) passed Linux checks and macOS 26/Xcode 26.2 compilation. Source: `580e3d6d4249cbb7f5c59b8feb2d1981964d862f`. All 19 local Node tests and browser flow checks passed. The browser's native hardware methods were mocked; camera/NFC operation is not physically verified yet.

Artifact `TURC-unsigned-4` contains version 0.2.0/build 4 and the NFC entitlement reference. Local file: `D:\Run Club\turc-ios\artifacts\build-4\TURC-unsigned.ipa`, 566,805 bytes. ZIP integrity, arm64 executable, version, bundle identifier, camera/NFC usage descriptions, entitlement reference, and bundled source metadata were verified. SHA-256: `314ad207978e8aa1f599e4004023561be5901c5d255fec668d2f904326bb0a8d`.

The hosted cleanup check found zero badges, courses, sessions, attempts, and laps after the rolled-back regressions. An Admin must configure the measured course and issue real fictional-runner badges through the app. No existing roster rows, accounts, website deployment, or paid-service settings were changed. Cloud artifact expires November 12; the local copy remains available.
