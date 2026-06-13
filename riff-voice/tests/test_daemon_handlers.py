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


# --- Single-writer config (daemon owns config.json) -----------------------


def test_set_default_voice_valid_persists(tmp_config):
    cfg, path = tmp_config
    daemon = RiffDaemon(cfg)
    voice = daemon_mod.KOKORO_VOICES[1]

    resp = daemon._handle_set_default_voice({"voice": voice})

    assert resp["ok"] is True
    assert _read(path)["default_voice"] == voice


def test_set_default_voice_invalid_errors_and_does_not_write(tmp_config):
    cfg, path = tmp_config
    daemon = RiffDaemon(cfg)

    resp = daemon._handle_set_default_voice({"voice": "bogus_voice"})

    assert "error" in resp
    assert not path.exists()


def test_set_announcer_voice_valid_persists(tmp_config):
    cfg, path = tmp_config
    daemon = RiffDaemon(cfg)
    voice = daemon_mod.KOKORO_VOICES[2]

    resp = daemon._handle_set_announcer_voice({"voice": voice})

    assert resp["ok"] is True
    assert _read(path)["announcer_voice"] == voice


def test_clear_sessions_empties_memory_and_disk(tmp_config):
    cfg, path = tmp_config
    cfg.session_names = {"abc": "Project A"}
    cfg.voice_map = {"abc": daemon_mod.KOKORO_VOICES[0]}
    daemon = RiffDaemon(cfg)

    resp = daemon._handle_clear_sessions()

    assert resp["ok"] is True
    assert daemon.config.session_names == {}
    assert daemon.config.voice_map == {}
    on_disk = _read(path)
    assert on_disk["session_names"] == {}
    assert on_disk["voice_map"] == {}


def test_get_config_returns_exactly_whitelisted_keys(tmp_config):
    cfg, _ = tmp_config
    daemon = RiffDaemon(cfg)

    resp = daemon._handle_get_config()

    assert resp["ok"] is True
    assert set(resp["config"].keys()) == {
        "default_voice",
        "announcer_voice",
        "session_names",
        "voice_map",
        "enabled",
        "speed",
        "output_device",
    }


def test_daemon_save_does_not_clobber_external_default_voice(tmp_config):
    """Regression: a daemon-side save (e.g. set_name auto-naming) must not
    revert a default_voice that was just changed through the daemon."""
    cfg, path = tmp_config
    daemon = RiffDaemon(cfg)
    new_voice = daemon_mod.KOKORO_VOICES[3]

    daemon._handle_set_default_voice({"voice": new_voice})
    # A later, unrelated save (session naming) writes the whole config again.
    daemon._handle_set_name({"session": "xyz", "name": "Some Session"})

    assert _read(path)["default_voice"] == new_voice


# --- Session pruning (bound unbounded growth) -----------------------------


def test_prune_sessions_caps_to_max_and_keeps_most_recent(tmp_config):
    cfg, _ = tmp_config
    daemon = RiffDaemon(cfg)
    total = daemon_mod.MAX_SESSIONS + 25
    for i in range(total):
        cfg.session_names[f"s{i:04d}"] = f"Session {i}"

    pruned = daemon._prune_sessions()

    assert pruned is True
    assert len(cfg.session_names) == daemon_mod.MAX_SESSIONS
    # The most recently inserted survive; the oldest are gone.
    assert f"s{total - 1:04d}" in cfg.session_names
    assert "s0000" not in cfg.session_names


def test_prune_sessions_noop_under_cap(tmp_config):
    cfg, _ = tmp_config
    daemon = RiffDaemon(cfg)
    cfg.session_names = {"a": "A", "b": "B"}

    assert daemon._prune_sessions() is False
    assert len(cfg.session_names) == 2


def test_prune_removes_voice_map_for_dropped_sessions(tmp_config):
    cfg, _ = tmp_config
    daemon = RiffDaemon(cfg)
    for i in range(daemon_mod.MAX_SESSIONS + 5):
        key = f"s{i:04d}"
        cfg.session_names[key] = f"Session {i}"
        cfg.voice_map[key] = daemon_mod.KOKORO_VOICES[i % len(daemon_mod.KOKORO_VOICES)]

    daemon._prune_sessions()

    # voice_map entries for pruned sessions are removed too.
    assert "s0000" not in cfg.voice_map
    assert set(cfg.voice_map.keys()) <= set(cfg.session_names.keys())
