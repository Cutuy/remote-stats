#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="build/Remote Stats.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
arch="${REMOTE_STATS_ARCH:-$(uname -m)}"
case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
swiftc -O -swift-version 5 -target "${arch}-apple-macosx13.0" -framework AppKit -framework SwiftUI macos/Protocol.swift macos/App.swift -o "$app/Contents/MacOS/RemoteStats"
cp macos/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "$PWD/$app"
