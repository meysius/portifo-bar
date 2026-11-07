#!/bin/zsh
# Builds a release binary for Apple silicon and Intel and wraps it in
# "build/Portifo Bar.app", signed ad hoc so macOS will run it and register it
# as a login item. VERSION (e.g. 1.2.0) and BUILD (a number that only goes
# up) stamp the bundle; releases set both from the tag and the CI run.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --arch arm64 --arch x86_64
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/PortifoBar"

app="build/Portifo Bar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/PortifoBar"
cp Resources/Info.plist "$app/Contents/Info.plist"

# The icon: Assets.car for macOS 26's Liquid Glass, AppIcon.icns before it.
# actool takes paths from where its helper runs, not from here: absolute only.
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$app/Contents/Resources" \
    --app-icon AppIcon --platform macosx --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$PWD/build/icon-info.plist" >/dev/null

plist="$app/Contents/Info.plist"
[[ -n "${VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$plist"
[[ -n "${BUILD:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$plist"

codesign --force --sign - --timestamp=none "$app"

echo "Built $app"
