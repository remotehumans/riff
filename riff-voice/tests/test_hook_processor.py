# ABOUTME: Tests for the Claude Code Stop hook's summary-extraction logic.
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
