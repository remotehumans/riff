#!/usr/bin/env bash
# ABOUTME: Claude Code Stop hook that sends assistant output to the Riff voice daemon.
# ABOUTME: Extracts SUMMARY line or first sentence from last_assistant_message and speaks it.

SOCKET_PATH="/tmp/riff.sock"

# Bail early if daemon socket doesn't exist
[ ! -S "$SOCKET_PATH" ] && exit 0

# Read stdin first (before anything else consumes it)
INPUT=$(cat 2>/dev/null || echo "{}")

# Do all parsing and sending in Python
python3 -c "
import sys, json, re, socket, os
from datetime import datetime

LOG = '/tmp/riff-hook-debug.log'
SOCK = '/tmp/riff.sock'

def log(msg):
    with open(LOG, 'a') as f:
        f.write(f'{datetime.now()}: {msg}\n')

try:
    raw = sys.argv[1]
    log(f'hook triggered, input length={len(raw)}')

    data = json.loads(raw)
    full_text = data.get('last_assistant_message', '')
    cwd = data.get('cwd', os.getcwd())
    session_id = data.get('session_id', '')

    # Use session_id as unique key (truncated for readability), fall back to folder name
    if session_id:
        session = session_id[:8]
    else:
        session = os.path.basename(cwd) if cwd else 'unknown'

    log(f'session={session}, session_id={session_id}, text length={len(full_text)}')

    if not full_text:
        log('no assistant message, exiting')
        sys.exit(0)

    # Extract SUMMARY line - supports optional [label] tag
    # Format: SUMMARY [Label Here]: The actual summary text.
    # or:     SUMMARY: The actual summary text.
    label = None
    match = re.search(r'SUMMARY\s*\[([^\]]+)\]\s*:\s*(.+)', full_text)
    if match:
        label = match.group(1).strip()
        speak_text = match.group(2).strip()
    else:
        match = re.search(r'SUMMARY:\s*(.+)', full_text)
        if match:
            speak_text = match.group(1).strip()
        else:
            match = re.match(r'([^.]+\.)', full_text)
            if match:
                speak_text = match.group(1).strip()
            else:
                speak_text = full_text[:200]

    # Auto-name the session if a label was provided
    if label:
        try:
            ns = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            ns.settimeout(2)
            ns.connect(SOCK)
            ns.send((json.dumps({'type': 'set_name', 'session': session, 'name': label}) + '\n').encode())
            ns.recv(4096)
            ns.close()
        except Exception:
            pass

    log(f'label={label}, speak_text={speak_text[:100]}')

    if not speak_text:
        sys.exit(0)

    # Send to Riff daemon
    msg = json.dumps({
        'type': 'speak',
        'text': speak_text,
        'session': session,
        'full_text': full_text
    }) + '\n'

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect(SOCK)
    s.send(msg.encode())
    resp = s.recv(4096)
    s.close()
    log(f'sent to daemon, response={resp.decode()}')

except Exception as e:
    try:
        with open(LOG, 'a') as f:
            f.write(f'ERROR: {e}\n')
    except:
        pass
" "$INPUT" 2>/dev/null || true

exit 0
