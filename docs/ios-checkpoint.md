# TURC iOS foundation

Prepared November 9, 2026, America/Los_Angeles.

## Source and backend

- Website baseline: published Site version 7, source `b6b7c85ad1952e320a95080ec1c0fe48dcb4a202`.
- Source copied from `D:\Run Club\turc-source-review\.sites-checkout\dist` into `web/`.
- Existing hosted Supabase project: `gafdrcjkcwazfeebmhgd`.
- Roster migrations remain in `D:\Run Club\backend\supabase\migrations`.
- No hosted schema, Auth configuration, website publication, or subscription changes made.
- Supabase public URL/key are intentionally shipped client configuration. Never add a service-role key, database password, real roster export, or signing key.
- Original Supabase SDK license/integrity record retained in `web/vendor/`.
- Owner explicitly selected the public repository `richardmeyer2003/truc-ios` (repository spelling retained).

## Technical choices

Capacitor core/CLI/iOS 8.6.0 and App plugin 8.1.2 are pinned. Swift Package Manager avoids a CocoaPods setup. GitHub macOS 26/Xcode 26.2 builds a Release device app with signing disabled, then packages `Payload/TURC.app` in an IPA. This bypasses the signed export process; the owner supplies signing later.

The existing CSS glass design is preserved. It is not a SwiftUI rewrite. Native changes cover secure session persistence, lifecycle refresh, explicit website opening, and CSV sharing. The native bridge exposes only TURC's three session keys and two known CSV export names.

## Next device acceptance

Local verification passed: 14 Node test entries (11 refresh regressions, CSV checks, and two native-storage tests), native project/XML/plist structural checks, and IPA shell syntax. Headless Chrome checked the app at 440 × 956 CSS pixels with fictional data: sign-in, roster rendering, no horizontal overflow, resume/search retention, and sign-out. The real vendored SDK also opened the signed-out screen successfully. No live authenticated iOS test has occurred.

- [ ] macOS Actions compilation succeeds and artifact contains an arm64 device executable.
- [ ] Sign/sideload the IPA on iPhone 17 Pro Max with the owner's method.
- [ ] Sign in with an existing TURC adult account; verify correct school and role.
- [ ] Verify website-imported fictional runners appear in the app and app edits appear on the website.
- [ ] Relaunch the app; session restores from Keychain.
- [ ] Background/foreground the app and retain tab, search, and roster during refresh.
- [ ] Confirm loss of network retains the last displayed roster and never claims pending writes succeeded.
- [ ] Sign out, force-close, reopen; no account or roster returns.
- [ ] Import from Files and export via Save to Files.
- [ ] Verify independent Staff/Parent accounts cannot obtain Admin scope.
- [ ] Validate NFC entitlement support before implementing NTAG215 pairing/scanning.

The previous connected-roster checkpoint remains authoritative for the website. This document covers the new iOS foundation only.
