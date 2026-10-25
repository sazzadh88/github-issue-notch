#!/bin/bash
# Builds ~/Applications/Issue Island.app from main.swift. Re-run after editing, then reopen the app.
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/Issue Island.app"
mkdir -p "$APP/Contents/MacOS"
# The target is pinned: the SDK default can be newer than the installed macOS, and the app then won't launch.
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/IssueIsland" main.swift
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.issue-island</string>
  <key>CFBundleName</key><string>Issue Island</string>
  <key>CFBundleExecutable</key><string>IssueIsland</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP" # ad-hoc signature, needed for "Start at login" and notifications
echo "Built $APP"
# --zip: pack the app to share. ditto keeps the signature and bundle attributes intact (Finder's zip may not).
if [[ "${1:-}" == "--zip" ]]; then
  mkdir -p dist
  ditto -c -k --keepParent "$APP" "dist/Issue Island.zip"
  echo "Packed dist/Issue Island.zip"
fi
