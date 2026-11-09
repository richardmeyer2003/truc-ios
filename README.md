# TURC for iPhone

TURC 0.3.0 uses read-only NTAG215 factory UID assignment, printable student badges with QR codes, native camera/NFC scanning, and shared online lap records. It preserves the connected Liquid Glass clubhouse and existing Supabase accounts/roster. The app never writes to NFC tags.

Develop on Windows. GitHub-hosted macOS compiles the iPhone app. The workflow produces an **unsigned IPA** for the owner's existing signing/sideloading process. No Apple developer credentials, Mac computer, TestFlight, or paid build service are required to prepare the build.

## First build

1. Push this repository to `richardmeyer2003/truc-ios` on GitHub (the chosen repository spelling).
2. Open **Actions → TURC iOS → Run workflow**, selecting `main`.
3. Wait for `checks` and `unsigned-ipa` to succeed.
4. Download `TURC-unsigned-<run number>` from that run's artifacts. Extract the artifact ZIP to find `TURC-unsigned.ipa`, checksum, and build details.
5. Sign and install the IPA using your own method.
6. Sign in with the same **TURC email/password** used on the website. Signing into GitHub or the Supabase dashboard does not sign into TURC.

Ordinary pushes and pull requests run Linux checks only. Manual dispatches, `ios-*` tags, and pushes with `[build-ios]` in the commit message also run the macOS build. Artifact retention is three days. No signing secrets or Supabase administrative credentials are needed in GitHub. The owner selected a public repository so standard hosted Actions compute is free; do not select paid larger runners.

## Windows development

Install Node 22+ and the pinned package manager, then:

```powershell
npm install --global pnpm@11.25.0
pnpm install --frozen-lockfile
pnpm test
pnpm build
pnpm preview
```

Preview at `http://127.0.0.1:4173`. Browser preview stores its own browser session; the iOS build uses Keychain storage. `pnpm ios:sync` prepares native assets without launching Xcode. Only macOS CI can compile or run the iOS application.

## Included

- Connected email/password login and live, RLS-protected school access.
- Admin/Staff/Parent roster views, search, runner details, and existing Admin roster operations.
- CSV preview/atomic import and formula-safe export. On iOS, exports use the share sheet, including Save to Files.
- Version 7 quiet-refresh behavior and native foreground refresh.
- Keychain-backed auth tokens, device-only and accessible while unlocked. No native fallback to localStorage on Keychain errors.
- Bundled assets, restricted content security policy, and existing TURC colors/materials with iPhone safe-area support.

## Scanning setup

1. As an Admin, open **Scan → Course settings**. Enter the measured lap length in meters and minimum lap interval; no default distance is invented.
2. Select the student under **Runners → View → QR / NFC badge**.
3. Choose **Scan NTAG215 UID** and present that student's sticker. The app reads its factory UID and assigns it to the student in Supabase. An already-assigned UID is rejected for another student; no tag memory is changed.
4. Choose **Generate printable badge**. Share/save/print the PDF with student name, school, grade/classroom, Student ID, and linked QR. It has a 2.52 × 3.54 inch insert with cut guides centered on US Letter; print at 100% / Actual Size and check physical fit. Reopening an existing assignment preserves its QR. Batch multi-badge sheets are later work.
5. Admin or Staff: open **Scan**, then **Open QR camera** or **Scan NFC stickers**. QR stays open; NFC uses Apple's time-limited reader sheet and can be restarted. The two adapters intentionally pause the camera during an NFC sheet.

UID reading requires your signing method to preserve/provision `com.apple.developer.nfc.readersession.formats = [TAG]`. The build artifact includes `TURC-required.entitlements` as a reference. An unsigned app cannot grant capabilities that its eventual signature/provisioning does not support. Camera QR scanning works independently after a badge has been assigned.

Accepted laps are saved centrally with captured course distance, school-local date, active year, operator, and badge history. The NFC UID and printed QR resolve to the same saved student assignment. Duplicate retries return their original result; a student lock protects the cooldown across devices. Replacing a sticker retires its old UID and QR without changing historical laps.

This milestone requires an online result. If a response is lost, the app retains the same event in memory for **Retry last scan** rather than claiming success. Force-closing loses that retry; a server-committed lap remains saved. Durable offline queues, corrections, schedule warnings, milestones, and calibrated badge sheets remain later work. Physical camera and NFC behavior must be checked on the actual phone.

## Layout

- `web/`: connected website assets, initially copied from Site version 7; native adjustments live here.
- `src/`: native JavaScript bridge and Supabase storage adapter.
- `ios/`: generated Xcode project plus TURC Keychain/share-sheet bridge.
- `scripts/`: asset build, preview server, native structural checks, unsigned IPA packaging.
- `tests/`: inherited refresh and CSV regressions plus native storage checks.
- `docs/`: baseline provenance and device acceptance checklist.
- `backend/`: the already-applied shared migrations and transactional SQL regressions; do not blindly reapply them to the live project.

App identifier: `org.turc.clubhouse`. The sideloading tool may adjust it; use a consistent signing identity/identifier across installs to preserve Keychain access. Keychain items may survive uninstall. This prototype does not implement app-uninstall account deletion.

## Validation boundary

Local JavaScript tests and native structural checks are not evidence of a successful Xcode build. The first macOS Actions run must pass before an IPA exists. Keychain, share-sheet CSV delivery, lifecycle behavior, and authenticated shared-roster access must then be verified on the iPhone 17 Pro Max. Fictional students only.
