#!/usr/bin/env bash
# Turns a fresh checkout of platforms/ios (the iOS 26 app) into an iOS 15 build tree, in place.
# Nothing under platforms/ios is committed back: this only runs on the CI runner's checkout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/ios"

sed -i.bak 's/\.iOS("26\.0")/.iOS("15.0")/' "$IOS/Package.swift" "$IOS/ios/KumoneIOSPackage/Package.swift"
sed -i.bak 's/iOS: "26\.0"/iOS: "15.0"/' "$IOS/ios/project.yml"
sed -i.bak 's/IPHONEOS_DEPLOYMENT_TARGET = 26\.0/IPHONEOS_DEPLOYMENT_TARGET = 15.0/' "$IOS/ios/Config/Shared.xcconfig"
find "$IOS" -name '*.bak' -delete

# iOS 15 stand-ins for newer SwiftUI / Foundation API; compiled into the same module so they shadow the SDK names.
mkdir -p "$IOS/Sources/Kumone/_IOS15"
cp "$ROOT"/ios15/Polyfills/*.swift "$IOS/Sources/Kumone/_IOS15/" 2>/dev/null || true

# Optional text patches for the few spots a shim cannot cover.
if [ -x "$ROOT/ios15/patches.py" ]; then python3 "$ROOT/ios15/patches.py" "$IOS"; fi
echo "iOS 15 tree ready"
