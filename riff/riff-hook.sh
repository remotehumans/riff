#!/usr/bin/env bash
# ABOUTME: Claude Code Stop hook that sends assistant output to the Riff voice daemon.
# ABOUTME: Extracts summary or first sentence from transcript and speaks it via Unix socket.

# Never fail - hook errors must not block Claude Code
set -o pipefail 2>/dev/null || true
trap 'exit 0' ERR

SOCKET_PATH="/tmp/riff.sock"

# Bail early if daemon socket doesn't exist
if [ ! -S "$SOCKET_PATH" ]; then
    exit 0
fi

# Read hook JSON from stdin (defensive - might be empty or malformed)
INPUT=$(cat 2>/dev/null || echo "{}")

# Extract fields from hook JSON
TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('transcript_path',''))" 2>/dev/null || echo "")
CWD=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || echo "")

# Derive session name from cwd
if [ -n "$CWD" ]; then
    SESSION=$(basename "$CWD")
else
    SESSION=$(basename "$(pwd)")
fi

# Need a transcript to read from
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
    exit 0
fi

# Get the last assistant message from the JSONL transcript
FULL_TEXT=$(python3 -c "
import json, sys
last_msg = ''
with open(sys.argv[1], 'r') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if obj.get('role') == 'assistant':
                content = obj.get('content', '')
                if isinstance(content, str) and content:
                    last_msg = content
        except (json.JSONDecodeError, KeyError):
            continue
print(last_msg)
" "$TRANSCRIPT_PATH" 2>/dev/null || echo "")

# Nothing to say
if [ -z "$FULL_TEXT" ]; then
    exit 0
fi

# Extract summary: look for SUMMARY: line, else take first sentence
SPEAK_TEXT=$(python3 -c "
import re, sys
text = sys.stdin.read().strip()
# Look for SUMMARY: line
match = re.search(r'SUMMARY:\s*(.+)', text)
if match:
    print(match.group(1).strip())
else:
    # First sentence (up to first period followed by space or end)
    match = re.match(r'([^.]+\.)', text)
    if match:
        print(match.group(1).strip())
    else:
        # Fallback: first 200 chars
        print(text[:200])
" <<< "$FULL_TEXT" 2>/dev/null || echo "")

if [ -z "$SPEAK_TEXT" ]; then
    exit 0
fi

# Send to Riff daemon via Python one-liner (no socat dependency)
python3 -c "
import socket, json, sys
msg = {
    'type': 'speak',
    'text': sys.argv[1],
    'session': sys.argv[2],
    'full_text': sys.argv[3]
}
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect(sys.argv[4])
    s.send(json.dumps(msg).encode() + b'\n')
    s.recv(4096)
    s.close()
except Exception:
    pass
" "$SPEAK_TEXT" "$SESSION" "$FULL_TEXT" "$SOCKET_PATH" 2>/dev/null || true

exit 0
