# ABOUTME: Python processor for the Riff Stop hook - extracts summaries from Claude Code output.
# ABOUTME: Called by riff-hook.sh with the hook JSON as first argument.

import sys
import json
import re
import socket
import os
from datetime import datetime

LOG = "/tmp/riff-hook-debug.log"
SOCK = "/tmp/riff.sock"


def log(msg):
    with open(LOG, "a") as f:
        f.write(f"{datetime.now()}: {msg}\n")


def extract_spoken_text(full_text):
    """Extract text suitable for TTS from an assistant message."""
    # Try SUMMARY [label]: text
    match = re.search(r"SUMMARY\s*\[([^\]]+)\]\s*:\s*(.+)", full_text)
    if match:
        return match.group(1).strip(), match.group(2).strip()

    # Try SUMMARY: text
    match = re.search(r"SUMMARY:\s*(.+)", full_text)
    if match:
        return None, match.group(1).strip()

    # No SUMMARY line - extract a meaningful spoken version
    # Strip markdown formatting
    clean = re.sub(r"\*\*([^*]+)\*\*", r"\1", full_text)  # bold
    clean = re.sub(r"`[^`]+`", "", clean)  # inline code
    clean = re.sub(r"```[\s\S]*?```", "", clean)  # code blocks
    clean = re.sub(r"#+\s+", "", clean)  # headers
    clean = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", clean)  # links
    clean = re.sub(r"[-*]\s+", "", clean)  # bullet points
    clean = re.sub(r"\n+", " ", clean).strip()  # newlines to spaces
    clean = re.sub(r"\s+", " ", clean)  # collapse whitespace

    # Take first 2-3 sentences (up to 400 chars)
    sentences = re.split(r"(?<=[.!?])\s+", clean)
    speak_text = ""
    for s in sentences[:3]:
        if len(speak_text) + len(s) > 400:
            break
        speak_text += s + " "
    speak_text = speak_text.strip()

    if not speak_text:
        speak_text = clean[:300]

    return None, speak_text


def send_to_daemon(message):
    """Send a JSON message to the Riff daemon socket."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2)
        s.connect(SOCK)
        s.send(json.dumps(message).encode() + b"\n")
        resp = s.recv(4096)
        s.close()
        return resp.decode()
    except Exception:
        return None


def main():
    try:
        raw = sys.argv[1] if len(sys.argv) > 1 else ""
        log(f"hook triggered, input length={len(raw)}")

        if not raw:
            return

        data = json.loads(raw)
        full_text = data.get("last_assistant_message", "")
        cwd = data.get("cwd", os.getcwd())
        session_id = data.get("session_id", "")

        # Use session_id as unique key, fall back to folder name
        if session_id:
            session = session_id[:8]
        else:
            session = os.path.basename(cwd) if cwd else "unknown"

        log(f"session={session}, session_id={session_id}, text length={len(full_text)}")

        if not full_text:
            log("no assistant message, exiting")
            return

        label, speak_text = extract_spoken_text(full_text)

        # Auto-name the session if a label was provided
        if label:
            send_to_daemon({"type": "set_name", "session": session, "name": label})

        log(f"label={label}, speak_text={speak_text[:100]}")

        if not speak_text:
            return

        # Send to Riff daemon
        resp = send_to_daemon({
            "type": "speak",
            "text": speak_text,
            "session": session,
            "full_text": full_text,
        })
        log(f"sent to daemon, response={resp}")

    except Exception as e:
        try:
            log(f"ERROR: {e}")
        except Exception:
            pass


if __name__ == "__main__":
    main()
