# ABOUTME: Converts Claude Code and Codex completion payloads into Riff speech requests.
# ABOUTME: Reads hook JSON from stdin, extracts an audio-friendly summary, and sends it to Riff.

import sys
import json
import re
import socket
import os
from datetime import datetime

LOG = "/tmp/riff-hook-debug.log"
SOCK = "/tmp/riff.sock"


def log(msg):
    # Cap the debug log so it can't grow without bound in /tmp.
    try:
        if os.path.exists(LOG) and os.path.getsize(LOG) > 1_000_000:
            open(LOG, "w").close()
    except OSError:
        pass
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


def normalise_payload(data):
    """Normalise Claude Code and Codex completion events.

    Claude Code uses snake_case keys and emits JSON on stdin. Codex's notify
    command uses hyphenated keys and appends the JSON as one command argument;
    riff-codex-notify.sh converts that argument back to stdin before calling us.
    """
    is_codex = data.get("type") == "agent-turn-complete" or any(
        key in data for key in ("last-assistant-message", "thread-id", "turn-id")
    )

    # Codex may add more notification event types later. Only completed agent
    # turns contain a response that Riff should narrate.
    if is_codex and data.get("type") not in (None, "agent-turn-complete"):
        return None

    if is_codex:
        full_text = data.get("last-assistant-message", "")
        session_id = data.get("thread-id", "")
        source = "codex"
    else:
        full_text = data.get("last_assistant_message", "")
        session_id = data.get("session_id", "")
        source = "claude"

    cwd = data.get("cwd", os.getcwd())
    if session_id:
        short_id = str(session_id)[:8]
        session = f"codex-{short_id}" if is_codex else short_id
    else:
        folder = os.path.basename(cwd) if cwd else "unknown"
        session = f"codex-{folder}" if is_codex else folder

    return {
        "source": source,
        "full_text": full_text,
        "cwd": cwd,
        "session_id": session_id,
        "session": session,
    }


def build_speech_request(data):
    """Build daemon messages from a hook payload without performing I/O."""
    payload = normalise_payload(data)
    if not payload or not payload["full_text"]:
        return None

    label, speak_text = extract_spoken_text(payload["full_text"])
    if not speak_text:
        return None

    # Codex does not conventionally emit Riff's SUMMARY label. Give its tasks a
    # stable, recognisable name while retaining a unique voice per thread.
    if not label and payload["source"] == "codex":
        folder = os.path.basename(payload["cwd"]) if payload["cwd"] else "Task"
        folder = re.sub(r"[-_]+", " ", folder).strip()
        label = f"Codex {folder}" if folder else "Codex Task"

    return {
        "label": label,
        "speak": {
            "type": "speak",
            "text": speak_text,
            "session": payload["session"],
            "full_text": payload["full_text"],
        },
        "source": payload["source"],
        "session_id": payload["session_id"],
    }


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
        raw = sys.stdin.read()
        log(f"hook triggered, input length={len(raw)}")

        if not raw:
            return

        data = json.loads(raw)
        request = build_speech_request(data)
        if not request:
            log("no narratable assistant message, exiting")
            return

        speak = request["speak"]
        label = request["label"]
        log(
            f"source={request['source']}, session={speak['session']}, "
            f"session_id={request['session_id']}, text length={len(speak['full_text'])}"
        )

        # Auto-name the session if a label was provided
        if label:
            send_to_daemon({"type": "set_name", "session": speak["session"], "name": label})

        log(f"label={label}, speak_len={len(speak['text'])}")

        # Send to Riff daemon
        resp = send_to_daemon(speak)
        log(f"sent to daemon, response={resp}")

    except Exception as e:
        try:
            log(f"ERROR: {e}")
        except Exception:
            pass


if __name__ == "__main__":
    main()
