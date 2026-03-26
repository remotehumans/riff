# ABOUTME: CLI entry points for riff-say and riff-ctl commands.
# ABOUTME: Sends JSON messages to the Riff voice daemon via Unix socket.

import argparse
import json
import socket
import sys


def send_to_daemon(message: dict, socket_path: str = "/tmp/riff.sock") -> dict | None:
    """Send JSON message to daemon, return response."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(socket_path)
    s.send(json.dumps(message).encode() + b"\n")
    data = s.recv(8192)
    s.close()
    if data:
        return json.loads(data.decode())
    return None


def say():
    """Entry point for riff-say: speak text aloud via the Riff daemon."""
    parser = argparse.ArgumentParser(description="Send text to Riff voice daemon")
    parser.add_argument("text", help="Text to speak")
    parser.add_argument("--session", default=None, help="Session name")
    parser.add_argument("--voice", default=None, help="Voice to use")
    parser.add_argument("--full-text", default=None, help="Full response text for read-full feature")
    args = parser.parse_args()

    message = {"type": "speak", "text": args.text}
    if args.session:
        message["session"] = args.session
    if args.voice:
        message["voice"] = args.voice
    if args.full_text:
        message["full_text"] = args.full_text

    try:
        resp = send_to_daemon(message)
        if resp:
            print(json.dumps(resp, indent=2))
    except (ConnectionRefusedError, FileNotFoundError):
        print("riff daemon not running", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)


def ctl():
    """Entry point for riff-ctl: control the Riff daemon."""
    parser = argparse.ArgumentParser(description="Control the Riff voice daemon")
    parser.add_argument("command", choices=[
        "interrupt", "skip", "status", "voices", "full", "speed", "enable", "disable"
    ], help="Command to send")
    parser.add_argument("value", nargs="?", default=None, help="Value for commands that need one (e.g. speed 1.5)")
    args = parser.parse_args()

    command_map = {
        "interrupt": {"type": "interrupt"},
        "skip": {"type": "skip"},
        "status": {"type": "status"},
        "voices": {"type": "list_voices"},
        "full": {"type": "read_full"},
        "enable": {"type": "set_enabled", "enabled": True},
        "disable": {"type": "set_enabled", "enabled": False},
    }

    if args.command == "speed":
        if args.value is None:
            print("error: speed requires a value (e.g. riff-ctl speed 1.5)", file=sys.stderr)
            sys.exit(1)
        try:
            message = {"type": "set_speed", "speed": float(args.value)}
        except ValueError:
            print(f"error: invalid speed value: {args.value}", file=sys.stderr)
            sys.exit(1)
    else:
        message = command_map[args.command]

    try:
        resp = send_to_daemon(message)
        if resp is None:
            print("no response from daemon", file=sys.stderr)
            sys.exit(1)

        print(json.dumps(resp, indent=2))
    except (ConnectionRefusedError, FileNotFoundError):
        print("riff daemon not running", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
