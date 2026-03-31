#!/usr/bin/env bash
# ABOUTME: Claude Code Stop hook that sends assistant output to the Riff voice daemon.
# ABOUTME: Reads hook JSON from stdin and delegates to riff-hook-processor.py.

SOCKET_PATH="/tmp/riff.sock"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROCESSOR="$SCRIPT_DIR/riff-hook-processor.py"

# Bail early if daemon socket or processor doesn't exist
[ ! -S "$SOCKET_PATH" ] && exit 0
[ ! -f "$PROCESSOR" ] && exit 0

# Read stdin, pass to Python processor as argument
INPUT=$(cat 2>/dev/null || echo "{}")
python3 "$PROCESSOR" "$INPUT" 2>/dev/null || true

exit 0
