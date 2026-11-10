# School-year progress and concise scanner feedback

Version 0.4.0 uses the website's existing `turc_school_progress` RPC to attach effective school-year totals to authorized roster rows. Mileage and distance to the next milestone appear beside each name, with a progress bar between the previous and next milestones. Reopening the Runners tab refreshes totals; the existing quiet refresh also includes progress changes and retains loaded data on a failed request.

The milestone helper is copied from the connected website's `dist/progress.js`: 5, 10, 13.1 (Half marathon), 25, 26.2 (Marathon), and 50 miles. Integer millimeters determine threshold crossings. A positive remainder displays at least 0.01 miles, avoiding a premature zero before a target is reached. After 50 miles the interface says “All milestones reached.” Missing totals display as unavailable.

Successful QR and NFC feedback share one formatter and contain only the runner's name, today's mileage, and miles remaining to the next school-year milestone. Example: `Maya Example` / `Today 3.00 mi · 2.00 mi to next milestone`. Lap numbers, yearly totals, and lifetime totals are removed from this feedback. Server rejection and connection messages remain explicit so an unconfirmed lap cannot look accepted.

No hosted schema changes were made. The already-applied website progress/corrections migration is included in the backend snapshot for reproducibility. Accounts, roster permissions, server-side scans, shared cooldown, UID assignment, and read-only NFC hardware operations use their existing paths. Retry feedback still reflects the original server receipt.

Validation: 22 Node checks passed, including quiet progress refresh and all milestone boundaries; browser QA at 440px verified roster layout, no horizontal overflow, scanner feedback through the native bridge mock, and existing badge assignment/printing controls. Native project checks passed. Native hardware and the system NFC sheet require the installed build on the owner's phone.

## Verified artifact

[GitHub Actions build 8](https://github.com/richardmeyer2003/truc-ios/actions/runs/42753722264) passed Linux checks, macOS 26 / Xcode 26.2 compilation, and the existing printable-badge render/QR validation. Source: `693217c58d8c963dcac4d5a115b2189600e5af4d`.

The downloaded ARM64 IPA is `D:\Run Club\turc-ios\artifacts\build-8\TURC-unsigned.ipa`, version 0.4.0, build 8, bundle `org.turc.clubhouse`, 581,422 bytes. SHA-256: `3ef28649c9fce7058bd2506042bd811a302ef92268273972d9ffb9e5b4d31bf5`. Archive integrity, bundled display changes, metadata, and TAG entitlement were verified locally. Sign and install with the owner's existing method.

