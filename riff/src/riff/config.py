# ABOUTME: Configuration loader for the Riff daemon.
# ABOUTME: Reads ~/.config/riff/config.json, merges with defaults, and supports saving.

from __future__ import annotations

import json
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Dict


CONFIG_PATH = Path.home() / ".config" / "riff" / "config.json"

DEFAULTS = {
    "enabled": True,
    "model": "mlx-community/Kokoro-82M-bf16",
    "default_voice": "am_adam",
    "announcer_voice": "af_heart",
    "speed": 1.0,
    "voice_map": {},
    "socket_path": "/tmp/riff.sock",
    "announce_sessions": True,
}


@dataclass
class RiffConfig:
    enabled: bool = True
    model: str = "mlx-community/Kokoro-82M-bf16"
    default_voice: str = "am_adam"
    announcer_voice: str = "af_heart"
    speed: float = 1.0
    voice_map: Dict[str, str] = field(default_factory=dict)
    socket_path: str = "/tmp/riff.sock"
    announce_sessions: bool = True

    @classmethod
    def load(cls, path: Path | None = None) -> RiffConfig:
        """Load config from disk, merging with defaults for any missing keys."""
        config_path = path or CONFIG_PATH
        merged = dict(DEFAULTS)

        if config_path.exists():
            try:
                with open(config_path, "r") as f:
                    user = json.load(f)
                merged.update(user)
            except (json.JSONDecodeError, OSError):
                pass

        return cls(
            enabled=merged["enabled"],
            model=merged["model"],
            default_voice=merged["default_voice"],
            announcer_voice=merged["announcer_voice"],
            speed=float(merged["speed"]),
            voice_map=merged.get("voice_map", {}),
            socket_path=merged["socket_path"],
            announce_sessions=merged["announce_sessions"],
        )

    def save(self, path: Path | None = None) -> None:
        """Write current config to disk."""
        config_path = path or CONFIG_PATH
        config_path.parent.mkdir(parents=True, exist_ok=True)
        with open(config_path, "w") as f:
            json.dump(asdict(self), f, indent=2)

    def to_dict(self) -> dict:
        return asdict(self)
