# ABOUTME: Tests summary extraction and payload normalisation for Claude Code and Codex.
# ABOUTME: Loads riff-hook-processor.py by path (it is a standalone script, not a package module).

import importlib.util
from pathlib import Path

_PROC_PATH = Path(__file__).resolve().parent.parent / "riff-hook-processor.py"
_spec = importlib.util.spec_from_file_location("riff_hook_processor", _PROC_PATH)
hook = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hook)


def test_summary_with_label():
    label, text = hook.extract_spoken_text("SUMMARY [Build Bot]: The build passed cleanly.")
    assert label == "Build Bot"
    assert text == "The build passed cleanly."


def test_summary_without_label():
    label, text = hook.extract_spoken_text("Some preamble.\nSUMMARY: All tests pass.")
    assert label is None
    assert text == "All tests pass."


def test_markdown_fallback_strips_formatting_and_caps_length():
    md = "Some **bold** text with `inline code` and a [link](http://example.com). More here."
    label, text = hook.extract_spoken_text(md)
    assert label is None
    assert "**" not in text
    assert "`" not in text
    assert "](" not in text
    assert len(text) <= 400


def test_claude_payload_keeps_existing_session_format():
    request = hook.build_speech_request({
        "session_id": "12345678-abcd",
        "cwd": "/tmp/my-project",
        "last_assistant_message": "SUMMARY [Build Bot]: All tests pass.",
    })

    assert request["source"] == "claude"
    assert request["speak"]["session"] == "12345678"
    assert request["label"] == "Build Bot"
    assert request["speak"]["text"] == "All tests pass."


def test_codex_payload_uses_thread_and_hyphenated_message_keys():
    request = hook.build_speech_request({
        "type": "agent-turn-complete",
        "thread-id": "abcdef12-3456",
        "turn-id": "turn-1",
        "cwd": "/tmp/remote-humans-agi",
        "last-assistant-message": "Done. Codex is now connected to Riff.",
    })

    assert request["source"] == "codex"
    assert request["speak"]["session"] == "codex-abcdef12"
    assert request["label"] == "Codex remote humans agi"
    assert request["speak"]["text"] == "Done. Codex is now connected to Riff."


def test_codex_ignores_non_completion_notifications():
    request = hook.build_speech_request({
        "type": "approval-requested",
        "thread-id": "abcdef12-3456",
        "last-assistant-message": "This should not be spoken.",
    })

    assert request is None
