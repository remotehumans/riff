#!/usr/bin/env bash
# ABOUTME: Codex notify adapter that preserves Codex Computer Use and adds Riff narration.
# ABOUTME: Receives Codex's JSON argument, forwards it to both notification consumers, then exits.

PAYLOAD="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROCESSOR="$SCRIPT_DIR/riff-hook-processor.py"
SOCKET_PATH="/tmp/riff.sock"

[ -z "$PAYLOAD" ] && exit 0

# Codex supplies JSON on argv. Pipe it to the shared processor so large final
# messages are not copied into another child process's argument list.
if [ -S "$SOCKET_PATH" ] && [ -f "$PROCESSOR" ]; then
    printf '%s' "$PAYLOAD" | python3 "$PROCESSOR" 2>/dev/null || true
fi

# Codex Computer Use already owns Elliott's notify slot. Keep its turn-ended
# signal working when Riff becomes the configured dispatcher. It must run last:
# the client may terminate the notification process once the turn is handled.
# This path is optional, so the adapter remains harmless without Computer Use.
SKY_CLIENT="$HOME/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
if [ -x "$SKY_CLIENT" ]; then
    exec "$SKY_CLIENT" turn-ended "$PAYLOAD" >/dev/null 2>&1
fi

exit 0
