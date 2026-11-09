# Read-only UID badge workflow — November 9, 2026

The owner clarified the workflow: **select student → scan NTAG215 factory UID and assign it → generate printable badge with student information and linked QR**. Version 0.3.0 supersedes the version 0.2.0 NDEF-writing design. No tag-writing method remains in the native app.

## Implementation

- `NFCTagReaderSession` reads seven-byte MIFARE factory identifiers. The only transceive is NXP's read-only GET_VERSION command (0x60), used to verify NTAG215. No NDEF content is required, read as a credential, or changed.
- A server-validated Admin assignment binds the UID to the selected active/enrolled student. A global active-UID uniqueness constraint prevents assigning one sticker to two students. Requests are retry-safe. Another student's existing assignment is never silently overwritten.
- QR credentials are created only when saving a UID assignment. The old QR-first creation and NDEF-confirmation RPCs have had authenticated execution revoked. Existing applied migration files remain immutable; the additive migration is `20261109224925_turc_uid_badge_assignment`.
- NFC submits a factory UID; QR submits the assignment's opaque QR token. The server resolves either to the same badge/student and applies shared lap validation/cooldown. UIDs remain lookup keys, not authentication.
- A printable PDF contains name, school, grade/classroom, Student ID, and QR. One 2.52 × 3.54 inch insert is centered on US Letter with cut guides. Print at Actual Size and verify printer output/sleeve fit. Batch sheet layouts are not implemented.
- The same Swift PDF generator runs in macOS CI, which renders a fictional badge and decodes its QR with Vision before uploading artifacts.
- Native signing now requires the Core NFC **TAG** entitlement rather than NDEF. No Apple enrollment or paid-service change was made.

## Verification and remaining device checks

The updated transactional scanning suite passed 32 hosted checks, including assignment-before-QR, UID uniqueness, assignment retries, retired endpoints, old UID/QR revocation, and shared QR/UID lap processing. Fixtures were rolled back. The app's 20 Node checks include a source guard against tag-writing operations.

Physical UID reading, signature support, actual NTAG215 identification, sticker-to-student assignment, QR/NFC lap scans, and printed cut-size fit remain to be tested on the owner's phone and printer. Historical version 0.2.0 documentation records an abandoned workflow and is superseded by this document.


## Verified version 0.3.0, build 7

[GitHub Actions run 7](https://github.com/richardmeyer2003/truc-ios/actions/runs/42716958354) passed Linux checks, macOS 26/Xcode 26.2 compilation, PDF rendering, and Vision QR decoding. Source: `2635655adead7cf2c4e0116ce2de9a844263b9d6`. The final page and badge-detail PNGs were visually checked: complete student information, cut guides, sharp vector QR in standard orientation, and no overlapping content.

Verified unsigned app: `D:\Run Club\turc-ios\artifacts\build-7\TURC-unsigned.ipa`, 579,810 bytes, version 0.3.0/build 7, arm64, identifier `org.turc.clubhouse`. SHA-256: `243a1805550b3c7aef7c243fdc0890f0f980a8701c90cc62a1fd71ee8e2144eb`. The package includes the TAG entitlement reference and a fictional printable badge PDF. Its ZIP integrity, version, executable architecture, entitlement reference, and bundled source metadata were verified locally.

All 20 app tests, 32 updated scanning SQL checks, 36 roster permission checks, and 21 import checks passed. The mocked-native browser flow verified no QR/print button before UID assignment, followed by successful assignment and printable student data. Hosted cleanup found zero badges/UID assignments; legacy QR-first creation and anonymous UID assignment are disabled. Physical phone/signing support and printer fit remain unverified.
