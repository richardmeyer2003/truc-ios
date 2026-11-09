# TURC for iPhone

TURC 0.1.0 packages the connected Liquid Glass clubhouse from published Site version 7 into a Capacitor iOS app. It uses the existing Supabase accounts, roster, and server authorization. Website deployment and native releases are separate; this repository does not publish or modify the existing Site.

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

No NFC, camera scanning, badge assignment, lap recording, mileage, or offline scan queue is claimed in this build. These need subsequent backend contracts and physical-device verification. NFC will also depend on what capabilities the owner's signing method can provision. A successful sideload does not prove NFC availability.

## Layout

- `web/`: connected website assets, initially copied from Site version 7; native adjustments live here.
- `src/`: native JavaScript bridge and Supabase storage adapter.
- `ios/`: generated Xcode project plus TURC Keychain/share-sheet bridge.
- `scripts/`: asset build, preview server, native structural checks, unsigned IPA packaging.
- `tests/`: inherited refresh and CSV regressions plus native storage checks.
- `docs/`: baseline provenance and device acceptance checklist.

App identifier: `org.turc.clubhouse`. The sideloading tool may adjust it; use a consistent signing identity/identifier across installs to preserve Keychain access. Keychain items may survive uninstall. This prototype does not implement app-uninstall account deletion.

## Validation boundary

Local JavaScript tests and native structural checks are not evidence of a successful Xcode build. The first macOS Actions run must pass before an IPA exists. Keychain, share-sheet CSV delivery, lifecycle behavior, and authenticated shared-roster access must then be verified on the iPhone 17 Pro Max. Fictional students only.
