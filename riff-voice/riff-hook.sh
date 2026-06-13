#!/usr/bin/env bash
# ABOUTME: Claude Code Stop hook that sends assistant output to the Riff voice daemon.
# ABOUTME: Reads hook JSON from stdin and delegates to riff-hook-processor.py.

SOCKET_PATH="/tmp/riff.sock"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROCESSOR="$SCRIPT_DIR/riff-hook-processor.py"

# Bail early if daemon socket or processor doesn't exist
[ ! -S "$SOCKET_PATH" ] && exit 0
[ ! -f "$PROCESSOR" ] && exit 0

# Stream stdin straight to the Python processor. Passing the payload on argv
# risks ARG_MAX on large messages and exposes it in the process listing.
python3 "$PROCESSOR" 2>/dev/null || true

exit 0
