# ABOUTME: Build script for the RiffBar SwiftUI macOS menu bar app.
# ABOUTME: Compiles all Swift sources into a single arm64 binary and code-signs it.

set -euo pipefail

cd "$(dirname "$0")"

echo "Building RiffBar..."

swiftc -o RiffBar \
    -framework AppKit \
    -framework SwiftUI \
    -framework CoreAudio \
    -target arm64-apple-macosx13.0 \
    RiffBarApp.swift \
    DaemonConnection.swift \
    PopoverView.swift \
    SettingsView.swift \
    SessionRow.swift

echo "Code signing..."
codesign --force --sign "Apple Development" RiffBar

echo "RiffBar built successfully."
