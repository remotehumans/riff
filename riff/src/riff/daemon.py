# ABOUTME: Main asyncio daemon for Riff - a voice narrator that speaks text via MLX-Audio Kokoro TTS.
# ABOUTME: Listens on a Unix socket, accepts JSON commands, and plays speech through sounddevice.

from __future__ import annotations

import asyncio
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

import numpy as np
import sounddevice as sd

from riff.config import RiffConfig

# Available Kokoro voice presets
KOKORO_VOICES = [
    "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica",
    "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
    "am_adam", "am_echo", "am_eric", "am_liam", "am_michael", "am_onyx",
    "am_puck", "am_santa",
    "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
    "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
]


def log(msg: str) -> None:
    """Print a timestamped log line to stdout."""
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


class RiffDaemon:
    """Voice narrator daemon that queues and plays TTS audio."""

    def __init__(self, config: RiffConfig) -> None:
        self.config = config
        self.queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self.speaking = False
        self.interrupted = False
        self.current_session: str | None = None
        self.last_full_text: str | None = None
        self.model_path: str = config.model
        self._generate_audio: Any = None

    def _load_model(self) -> None:
        """Load the Kokoro TTS model and warm up with a test generation."""
        log(f"Loading model: {self.model_path}")
        from mlx_audio.tts.generate import load_model, generate_audio
        self._model = load_model(self.model_path)
        self._generate_audio = generate_audio

        # Warm-up generation to initialise pipeline caches
        log("Warming up model...")
        import tempfile
        tmpdir = tempfile.mkdtemp()
        self._generate_audio(
            text="ready",
            model=self._model,
            voice=self.config.default_voice,
            speed=1.0,
            lang_code="a",
            output_path=tmpdir,
            verbose=False,
        )
        # Clean up warm-up temp dir
        for f in os.listdir(tmpdir):
            os.unlink(os.path.join(tmpdir, f))
        os.rmdir(tmpdir)
        log("Model loaded and ready")

    def _synthesize(self, text: str, voice: str, speed: float) -> np.ndarray:
        """Generate audio from text using Kokoro TTS, return numpy array."""
        import tempfile
        import soundfile as sf

        tmpdir = tempfile.mkdtemp()
        self._generate_audio(
            text=text,
            model=self._model,
            voice=voice,
            speed=speed,
            lang_code="a",
            output_path=tmpdir,
            file_prefix="riff",
            verbose=False,
        )

        # Read the generated WAV file
        import os
        wav_files = [f for f in os.listdir(tmpdir) if f.endswith(".wav")]
        if not wav_files:
            raise RuntimeError("No audio file generated")

        audio_np, _ = sf.read(os.path.join(tmpdir, wav_files[0]))

        # Clean up temp files
        for f in os.listdir(tmpdir):
            os.unlink(os.path.join(tmpdir, f))
        os.rmdir(tmpdir)

        return audio_np.astype(np.float32)

    def _play_audio(self, audio_np: np.ndarray) -> None:
        """Play audio through sounddevice, with retry on device errors."""
        max_retries = 3
        for attempt in range(max_retries):
            try:
                sd.play(audio_np, samplerate=24000)

                # Wait for playback to finish, checking interrupt flag periodically
                stream = sd.get_stream()
                while stream is not None and stream.active:
                    if self.interrupted:
                        sd.stop()
                        return
                    sd.sleep(50)
                    stream = sd.get_stream()
                return  # Success
            except sd.PortAudioError as e:
                log(f"Audio device error (attempt {attempt + 1}/{max_retries}): {e}")
                sd.stop()
                if attempt < max_retries - 1:
                    # Reset sounddevice to pick up new/changed audio devices
                    try:
                        sd._terminate()
                        sd._initialize()
                        log("Audio device reset, retrying...")
                    except Exception:
                        import time
                        time.sleep(1)
                else:
                    log("Audio device failed after all retries, skipping this message")

    async def speech_worker(self) -> None:
        """Pull items from the speech queue and play them sequentially."""
        loop = asyncio.get_event_loop()

        while True:
            item = await self.queue.get()
            if not self.config.enabled:
                self.queue.task_done()
                continue

            self.interrupted = False
            self.speaking = True
            session = item.get("session", "unknown")
            text = item.get("text", "")
            voice = item.get("voice") or self.config.voice_map.get(session) or self.config.default_voice
            speed = self.config.speed

            self.current_session = session
            display_name = self.config.session_names.get(session)
            log(f"Speaking for [{display_name or session}]: {text[:80]}{'...' if len(text) > 80 else ''}")

            try:
                # Only announce if we have a human-friendly name (skip UUIDs/folder names)
                if self.config.announce_sessions and display_name:
                    announce_text = f"{display_name} says:"
                    audio_np = await loop.run_in_executor(
                        None, self._synthesize, announce_text, self.config.announcer_voice, 1.0
                    )
                    if not self.interrupted:
                        await loop.run_in_executor(None, self._play_audio, audio_np)

                # Speak the actual text (pass speed to Kokoro generator for proper speed control)
                if not self.interrupted:
                    audio_np = await loop.run_in_executor(
                        None, self._synthesize, text, voice, speed
                    )
                    if not self.interrupted:
                        await loop.run_in_executor(None, self._play_audio, audio_np)

            except Exception as e:
                log(f"Speech error: {e}")
            finally:
                self.speaking = False
                self.current_session = None
                self.queue.task_done()

    async def handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        """Handle a single client connection on the Unix socket."""
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break

                try:
                    msg = json.loads(line.decode("utf-8").strip())
                except (json.JSONDecodeError, UnicodeDecodeError):
                    response = {"error": "invalid JSON"}
                    writer.write((json.dumps(response) + "\n").encode())
                    await writer.drain()
                    continue

                response = await self._dispatch(msg)
                writer.write((json.dumps(response) + "\n").encode())
                await writer.drain()

        except (ConnectionResetError, BrokenPipeError):
            pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass

    async def _dispatch(self, msg: dict[str, Any]) -> dict[str, Any]:
        """Route an incoming message to the appropriate handler."""
        cmd = msg.get("type", "")

        if cmd == "speak":
            return self._handle_speak(msg)
        elif cmd == "interrupt":
            return self._handle_interrupt()
        elif cmd == "skip":
            return self._handle_skip()
        elif cmd == "status":
            return self._handle_status()
        elif cmd == "read_full":
            return self._handle_read_full(msg)
        elif cmd == "set_voice":
            return self._handle_set_voice(msg)
        elif cmd == "set_enabled":
            return self._handle_set_enabled(msg)
        elif cmd == "set_speed":
            return self._handle_set_speed(msg)
        elif cmd == "set_name":
            return self._handle_set_name(msg)
        elif cmd == "list_voices":
            return self._handle_list_voices()
        else:
            return {"error": f"unknown command: {cmd}"}

    def _handle_speak(self, msg: dict[str, Any]) -> dict[str, Any]:
        text = msg.get("text", "")
        if not text:
            return {"error": "missing text field"}

        # Store full_text for later read_full command
        full_text = msg.get("full_text")
        if full_text:
            self.last_full_text = full_text

        self.queue.put_nowait({
            "text": text,
            "session": msg.get("session", "unknown"),
            "voice": msg.get("voice"),
        })
        return {"ok": True, "queued": self.queue.qsize()}

    def _handle_interrupt(self) -> dict[str, Any]:
        self.interrupted = True
        sd.stop()
        # Drain the queue
        cleared = 0
        while not self.queue.empty():
            try:
                self.queue.get_nowait()
                self.queue.task_done()
                cleared += 1
            except asyncio.QueueEmpty:
                break
        log(f"Interrupted - cleared {cleared} queued items")
        return {"ok": True, "cleared": cleared}

    def _handle_skip(self) -> dict[str, Any]:
        self.interrupted = True
        sd.stop()
        log("Skipped current speech")
        return {"ok": True}

    def _handle_status(self) -> dict[str, Any]:
        return {
            "speaking": self.speaking,
            "queue_depth": self.queue.qsize(),
            "current_session": self.current_session,
            "enabled": self.config.enabled,
            "speed": self.config.speed,
        }

    def _handle_read_full(self, msg: dict[str, Any]) -> dict[str, Any]:
        if not self.last_full_text:
            return {"error": "no full_text stored"}

        session = msg.get("session", "narrator")
        self.queue.put_nowait({
            "text": self.last_full_text,
            "session": session,
            "voice": msg.get("voice"),
        })
        return {"ok": True, "queued": self.queue.qsize()}

    def _handle_set_voice(self, msg: dict[str, Any]) -> dict[str, Any]:
        session = msg.get("session")
        voice = msg.get("voice")
        if not session or not voice:
            return {"error": "missing session or voice field"}
        if voice not in KOKORO_VOICES:
            return {"error": f"unknown voice: {voice}", "available": KOKORO_VOICES}

        self.config.voice_map[session] = voice
        log(f"Voice for [{session}] set to {voice}")
        return {"ok": True, "session": session, "voice": voice}

    def _handle_set_enabled(self, msg: dict[str, Any]) -> dict[str, Any]:
        enabled = msg.get("enabled")
        if enabled is None:
            return {"error": "missing enabled field"}

        self.config.enabled = bool(enabled)
        state = "enabled" if self.config.enabled else "disabled"
        log(f"TTS {state}")
        return {"ok": True, "enabled": self.config.enabled}

    def _handle_set_speed(self, msg: dict[str, Any]) -> dict[str, Any]:
        speed = msg.get("speed")
        if speed is None:
            return {"error": "missing speed field"}

        try:
            speed = float(speed)
        except (ValueError, TypeError):
            return {"error": "speed must be a number"}

        if not 0.5 <= speed <= 3.0:
            return {"error": "speed must be between 0.5 and 3.0"}

        self.config.speed = speed
        log(f"Playback speed set to {speed}x")
        return {"ok": True, "speed": self.config.speed}

    def _handle_set_name(self, msg: dict[str, Any]) -> dict[str, Any]:
        session = msg.get("session")
        name = msg.get("name")
        if not session or not name:
            return {"error": "missing session or name field"}

        self.config.session_names[session] = name
        self.config.save()
        log(f"Session [{session}] named '{name}'")
        return {"ok": True, "session": session, "name": name}

    def _handle_list_voices(self) -> dict[str, Any]:
        return {"voices": KOKORO_VOICES}


async def run_daemon(config: RiffConfig) -> None:
    """Start the daemon: load model, launch socket server and speech worker."""
    daemon = RiffDaemon(config)

    # Load model (blocking, done before accepting connections)
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, daemon._load_model)

    # Clean up stale socket file
    sock_path = config.socket_path
    if os.path.exists(sock_path):
        os.unlink(sock_path)

    # Start Unix socket server
    server = await asyncio.start_unix_server(daemon.handle_client, path=sock_path)
    os.chmod(sock_path, 0o660)

    log(f"Listening on {sock_path}")

    # Start speech worker
    worker_task = asyncio.create_task(daemon.speech_worker())

    try:
        await server.serve_forever()
    except asyncio.CancelledError:
        pass
    finally:
        worker_task.cancel()
        server.close()
        await server.wait_closed()
        if os.path.exists(sock_path):
            os.unlink(sock_path)
        log("Daemon shut down")


def main() -> None:
    """Entry point for the Riff daemon."""
    config = RiffConfig.load()

    print()
    print("  ╭─────────────────────────────╮")
    print("  │  RIFF - Voice Narrator       │")
    print("  ╰─────────────────────────────╯")
    print(f"  Socket : {config.socket_path}")
    print(f"  Model  : {config.model}")
    print(f"  Voice  : {config.default_voice}")
    print(f"  Speed  : {config.speed}x")
    print()

    try:
        asyncio.run(run_daemon(config))
    except KeyboardInterrupt:
        log("Interrupted by user")
        sys.exit(0)


if __name__ == "__main__":
    main()
