#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build artifacts
xcodebuild -version
xcodebuild \
  -project ios/App/App.xcodeproj \
  -scheme App \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" \
  MARKETING_VERSION=0.4.0 \
  build 2>&1 | tee build/xcodebuild.log

app='build/DerivedData/Build/Products/Release-iphoneos/App.app'
test -f "$app/Info.plist"
test -f "$app/App"
test -f "$app/public/index.html"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")" = org.turc.clubhouse
lipo -info "$app/App" | grep -q arm64
# Use a unique staging directory, leaving the build products intact.
stage="$(mktemp -d "$PWD/build/package.XXXXXX")"
mkdir -p "$stage/Payload"
ditto "$app" "$stage/Payload/TURC.app"
ditto -c -k --keepParent "$stage/Payload" artifacts/TURC-unsigned.ipa
unzip -t artifacts/TURC-unsigned.ipa
shasum -a 256 artifacts/TURC-unsigned.ipa > artifacts/SHA256SUMS.txt
cp www/build-info.json artifacts/build-info.json
cp ios/App/App/TURC.entitlements artifacts/TURC-required.entitlements
cat > artifacts/README.txt <<'EOF'
TURC 0.4.0 — unsigned iPhone app
Sign this IPA using your own signing method before installing it.
No Apple signing credentials or provisioning profiles are included.
Sign in with your existing TURC website account, not your GitHub dashboard account.
This build connects to the existing Supabase roster. Use fictional students only.
Native camera QR and read-only NFC UID scanners share the authenticated badge/lap API.
Admins: select runner > QR / NFC badge > scan NTAG215 UID > generate printable badge PDF.
The app never writes to NFC tags. Both the sticker UID and printed QR resolve to the saved student assignment.
Print the Letter PDF at 100% / Actual Size; cut guides mark a 2.52 by 3.54 inch insert.
NFC requires your signing method to preserve/provision the included TURC-required.entitlements.
An unsigned build cannot grant capabilities unsupported by your signing method. QR works separately.
Laps require an online confirmation. Durable offline queues and correction tools remain future work.
EOF
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat artifacts/README.txt >> "$GITHUB_STEP_SUMMARY"
fi
