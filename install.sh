#!/bin/sh
# Installs Portifo Bar from the latest GitHub release, or updates it: run it
# again to get the newest version.
#
#   curl -fsSL https://raw.githubusercontent.com/meysius/portifo-bar/main/install.sh | sh
#
# The app isn't notarized by Apple. A browser marks what it downloads as
# quarantined, and macOS then refuses to open an app it can't vouch for;
# curl adds no such mark, so the app opens as any other.
set -eu

repo="meysius/portifo-bar"
app="Portifo Bar.app"

# /Applications, where Launch at Login expects the app, if this account can
# write there; otherwise the account's own Applications folder.
dest=/Applications
[ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Portifo Bar…"
curl -fsSL "https://github.com/$repo/releases/latest/download/PortifoBar.zip" -o "$tmp/PortifoBar.zip"
ditto -x -k "$tmp/PortifoBar.zip" "$tmp"

pkill -x PortifoBar 2>/dev/null || true
rm -rf "$dest/$app"
mv "$tmp/$app" "$dest/"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$dest/$app/Contents/Info.plist")
echo "Installed Portifo Bar $version in $dest. It's in the menu bar."
open "$dest/$app"
