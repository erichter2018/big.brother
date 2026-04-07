#!/usr/bin/env bash
set -euo pipefail

# App Store Connect API credentials
API_KEY="74AAPQBWP9"
API_ISSUER="5e4d4222-7573-42c9-96e7-fb8ed03550b8"
API_KEY_PATH="$HOME/.private_keys/AuthKey_${API_KEY}.p8"

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEME="BigBrother"
ARCHIVE_PATH="$PROJECT_DIR/build/BigBrother.xcarchive"
EXPORT_PATH="$PROJECT_DIR/build/export"

echo "=== Big Brother → App Store Upload ==="
echo ""

# 1. Read build number from AppConstants.swift
BUILD_NUM=$(grep 'appBuildNumber' "$PROJECT_DIR/BigBrotherCore/Sources/BigBrotherCore/Constants/AppConstants.swift" | grep -o '[0-9]\+')
echo "Build number: $BUILD_NUM"

# 2. Sync CFBundleVersion in all Info.plist files
echo "Syncing CFBundleVersion → $BUILD_NUM in all plists..."
for plist in \
    "$PROJECT_DIR/BigBrotherApp/Info.plist" \
    "$PROJECT_DIR/BigBrotherMonitor/Info.plist" \
    "$PROJECT_DIR/BigBrotherShield/Info.plist" \
    "$PROJECT_DIR/BigBrotherShieldAction/Info.plist" \
    "$PROJECT_DIR/BigBrotherWidget/Info.plist" \
    "$PROJECT_DIR/BigBrotherTunnel/Info.plist" \
    "$PROJECT_DIR/BigBrotherActivityReport/Info.plist"; do
    if [ -f "$plist" ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$plist" 2>/dev/null || true
    fi
done

# 3. Verify API key exists
if [ ! -f "$API_KEY_PATH" ]; then
    echo "ERROR: API key not found at $API_KEY_PATH"
    exit 1
fi

# 4. Clean previous build artifacts
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p "$PROJECT_DIR/build"

# 5. Archive (release build)
echo ""
echo "Archiving..."
xcodebuild archive \
    -project "$PROJECT_DIR/BigBrother.xcodeproj" \
    -scheme "$SCHEME" \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$API_KEY_PATH" \
    -authenticationKeyID "$API_KEY" \
    -authenticationKeyIssuerID "$API_ISSUER" \
    -quiet

if [ ! -d "$ARCHIVE_PATH" ]; then
    echo "ERROR: Archive failed — no .xcarchive produced"
    exit 1
fi
echo "Archive complete: $ARCHIVE_PATH"

# 6. Create ExportOptions.plist for App Store distribution
cat > "$PROJECT_DIR/build/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>Y2G5FUN342</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>destination</key>
    <string>upload</string>
</dict>
</plist>
PLIST

# 7. Export IPA
echo ""
echo "Exporting IPA..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$PROJECT_DIR/build/ExportOptions.plist" \
    -exportPath "$EXPORT_PATH" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$API_KEY_PATH" \
    -authenticationKeyID "$API_KEY" \
    -authenticationKeyIssuerID "$API_ISSUER" \
    -quiet

IPA_PATH=$(find "$EXPORT_PATH" -name "*.ipa" | head -1)
if [ -z "$IPA_PATH" ]; then
    echo "ERROR: Export failed — no .ipa produced"
    exit 1
fi
echo "IPA exported: $IPA_PATH"

# 8. Upload to App Store Connect
echo ""
echo "Uploading to App Store Connect..."
xcrun altool --upload-app \
    -f "$IPA_PATH" \
    -t ios \
    --apiKey "$API_KEY" \
    --apiIssuer "$API_ISSUER" \
    2>&1

echo ""
echo "=== Upload complete! Build $BUILD_NUM ==="
echo "Check status: https://appstoreconnect.apple.com/apps"
echo "TestFlight should show it in ~15-30 minutes after processing."
