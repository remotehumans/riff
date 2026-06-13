# ABOUTME: Unit tests for RiffDaemon command handlers — persistence and device scanning.
# ABOUTME: Pure-logic tests; no audio device, socket, or MLX model required.

import asyncio
import json

import pytest

import riff.config as config_mod
import riff.daemon as daemon_mod
from riff.config import RiffConfig
from riff.daemon import RiffDaemon


@pytest.fixture
def tmp_config(tmp_path, monkeypatch):
    """A RiffConfig whose save() lands in a temp file, not the real ~/.config."""
    cfg_path = tmp_path / "config.json"
    monkeypatch.setattr(config_mod, "CONFIG_PATH", cfg_path)
    return RiffConfig(), cfg_path


def _read(path):
    return json.loads(path.read_text())


def test_set_speed_persists(tmp_config):
    cfg, path = tmp_config
    daemon = RiffDaemon(cfg)

    resp = daemon._handle_set_speed({"speed": 1.7})

    assert resp["ok"] is True
    assert resp["speed"] == 1.7
    assert _read(path)["speed"] == 1.7


def test_set_speed_out_of_range_errors_and_does_not_write(tmp_config):
    cfg, path = tmp_config
    daemon = RiffDaemon(cfg)

    resp = daemon._handle_set_speed({"speed": 9})

    assert "error" in resp
    assert not path.exists()


def test_set_enabled_persists(tmp_config):
    cfg, path = tmp_config
    daemon = RiffDaemon(cfg)

    resp = daemon._handle_set_enabled({"enabled": False})

    assert resp["ok"] is True
    assert resp["enabled"] is False
    assert _read(path)["enabled"] is False


def test_set_voice_valid_persists(tmp_config):
    cfg, path = tmp_config
    daemon = RiffDaemon(cfg)
    valid_voice = daemon_mod.KOKORO_VOICES[0]

    resp = daemon._handle_set_voice({"session": "proj-x", "voice": valid_voice})

    assert resp["ok"] is True
    assert _read(path)["voice_map"]["proj-x"] == valid_voice


def test_set_voice_invalid_errors_and_does_not_write(tmp_config):
    cfg, path = tmp_config
    daemon = RiffDaemon(cfg)

    resp = daemon._handle_set_voice({"session": "proj-x", "voice": "not_a_voice"})

    assert "error" in resp
    assert not path.exists()


def test_rescan_skipped_while_speaking(tmp_config, monkeypatch):
    cfg, _ = tmp_config
    daemon = RiffDaemon(cfg)
    daemon.speaking = True

    fake_devices = [
        {"name": "Speaker", "max_output_channels": 2, "max_input_channels": 0},
        {"name": "Mic", "max_output_channels": 0, "max_input_channels": 1},
    ]
    monkeypatch.setattr(daemon_mod.sd, "query_devices", lambda *a, **k: fake_devices)

    class _FakeDefault:
        device = (1, 0)  # (input_index, output_index)

    monkeypatch.setattr(daemon_mod.sd, "default", _FakeDefault())

    def _boom():
        raise AssertionError("_terminate must not run while speaking")

    monkeypatch.setattr(daemon_mod.sd, "_terminate", _boom)

    resp = asyncio.run(daemon._handle_list_devices({"rescan": True}))

    assert resp.get("rescan_skipped") is True
    assert len(resp["output_devices"]) == 1
    assert len(resp["input_devices"]) == 1
