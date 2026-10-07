#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-icon.sh
# Keep shell credentials and unrelated signing/build settings out of SwiftPM.
# Public dependencies need neither Keychain nor .netrc authentication.
build() {
    /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
        /usr/bin/swift build -c release -debug-info-format none --disable-keychain --disable-netrc \
        --scratch-path "$PWD/.build/package" \
        --cache-path "$PWD/.build/package-cache" \
        --config-path "$PWD/.build/package-config" \
        --security-path "$PWD/.build/package-security" \
        -Xswiftc -file-prefix-map -Xswiftc "$PWD=/src/Transcriber" \
        -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/src/Transcriber" "$@"
}
build
BIN_DIR="$(build --show-bin-path)"
# Assemble from an empty directory so previous builds cannot leak extra files.
mkdir -p "$PWD/dist"
STAGING="$(mktemp -d "$PWD/dist/.package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Transcriber.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"
cp "$BIN_DIR/Transcriber" "$APP/Contents/MacOS/Transcriber"
# SwiftPM derives the artifact directory from the checkout directory name.
FRAMEWORKS=("$PWD"/.build/package/artifacts/*/whisper/whisper.xcframework/macos-arm64_x86_64/whisper.framework)
if [ "${#FRAMEWORKS[@]}" -ne 1 ] || [ ! -d "${FRAMEWORKS[0]}" ]; then
    printf 'Expected exactly one downloaded Whisper framework.\n' >&2
    exit 1
fi
ditto --norsrc --noextattr "${FRAMEWORKS[0]}" "$APP/Contents/Frameworks/whisper.framework"
# Resolve the bundled engine after moving the app away from the build directory.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Transcriber"
# Drop the development framework search path from the portable application.
BUILD_RPATH="$(otool -l "$APP/Contents/MacOS/Transcriber" | awk '/LC_RPATH/{getline; getline; if ($2 ~ /\/\.build\//) print $2}')"
if [ -n "$BUILD_RPATH" ]; then
    install_name_tool -delete_rpath "$BUILD_RPATH" "$APP/Contents/MacOS/Transcriber"
fi
cp THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R "$BIN_DIR/Transcriber_TranscriberCore.bundle" "$APP/Contents/Resources/"
# SwiftPM can include the checkout directory name in the resource bundle ID.
/usr/bin/plutil -replace CFBundleIdentifier -string local.transcriber.resources \
    "$APP/Contents/Resources/Transcriber_TranscriberCore.bundle/Contents/Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Transcriber</string>
<key>CFBundleIdentifier</key><string>local.transcriber</string>
<key>CFBundleName</key><string>Transcriber</string>
<key>CFBundleDisplayName</key><string>Transcriber</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>13.3</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
# Remove debug paths and filesystem metadata before sealing the bundle.
/usr/bin/strip -S "$APP/Contents/MacOS/Transcriber"
/usr/bin/xattr -cr "$APP"
# The literal '-' always selects ad-hoc signing, without any private key.
/usr/bin/codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/whisper.framework"
/usr/bin/codesign --force --sign - --timestamp=none "$APP"
/usr/bin/python3 scripts/verify-app.py "$APP"
rm -rf "$PWD/dist/Transcriber.app"
mv "$APP" "$PWD/dist/Transcriber.app"
APP="$PWD/dist/Transcriber.app"
printf '\nBuilt: %s\n' "$APP"
