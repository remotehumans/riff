# ABOUTME: Main asyncio daemon for Riff - a voice narrator that speaks text via MLX-Audio Kokoro TTS.
# ABOUTME: Listens on a Unix socket, accepts JSON commands, and plays speech through sounddevice.

from __future__ import annotations

import asyncio
import json
import os
import re
import subprocess
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

# Voices to auto-assign to new sessions (distinct, easy to tell apart)
# Excludes default_voice and announcer_voice so they stay unique
AUTO_ASSIGN_VOICES = [
    "bf_emma", "am_echo", "af_nova", "bm_george", "af_bella",
    "am_liam", "bf_lily", "bm_daniel", "af_jessica", "am_eric",
    "af_river", "bm_fable", "af_kore", "am_michael", "bf_isabella",
    "af_sarah", "am_onyx", "bm_lewis", "af_alloy", "am_puck",
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

    def _duck_audio(self) -> dict | None:
        """Pause system media before Riff speaks. Only pauses what's actually playing."""
        if self.config.audio_mode == "none":
            return None

        state: dict = {"paused_system": False, "paused_apps": []}

        # Check and pause specific media apps (only if actually playing)
        apps = [
            ("Music",
             'tell application "Music" to player state is playing',
             'tell application "Music" to pause'),
            ("Spotify",
             'tell application "Spotify" to player state is playing',
             'tell application "Spotify" to pause'),
        ]
        for app_name, check_script, pause_script in apps:
            try:
                running = subprocess.run(
                    ["osascript", "-e",
                     f'tell application "System Events" to (name of processes) contains "{app_name}"'],
                    capture_output=True, text=True, timeout=2
                )
                if "true" not in running.stdout.lower():
                    continue
                playing = subprocess.run(
                    ["osascript", "-e", check_script],
                    capture_output=True, text=True, timeout=2
                )
                if "true" not in playing.stdout.lower():
                    continue
                subprocess.run(["osascript", "-e", pause_script], capture_output=True, timeout=2)
                state["paused_apps"].append(app_name)
                log(f"Paused {app_name}")
            except Exception:
                pass

        # Pause browser media via JavaScript injection - only if something is actually playing
        browsers = [
            ("Arc",
             'tell application "Arc" to tell front window to tell active tab to execute javascript "Array.from(document.querySelectorAll(\\"video, audio\\")).some(m => !m.paused)"',
             'tell application "Arc" to tell front window to tell active tab to execute javascript "document.querySelectorAll(\\"video, audio\\").forEach(m => { if(!m.paused) m.pause() })"'),
            ("Google Chrome",
             'tell application "Google Chrome" to execute active tab of front window javascript "Array.from(document.querySelectorAll(\\"video, audio\\")).some(m => !m.paused)"',
             'tell application "Google Chrome" to execute active tab of front window javascript "document.querySelectorAll(\\"video, audio\\").forEach(m => { if(!m.paused) m.pause() })"'),
            ("Safari",
             'tell application "Safari" to do JavaScript "Array.from(document.querySelectorAll(\\"video, audio\\")).some(m => !m.paused)" in front document',
             'tell application "Safari" to do JavaScript "document.querySelectorAll(\\"video, audio\\").forEach(m => { if(!m.paused) m.pause() })" in front document'),
        ]
        state["paused_browsers"] = []
        for browser_name, check_script, pause_script in browsers:
            try:
                running = subprocess.run(
                    ["osascript", "-e",
                     f'tell application "System Events" to (name of processes) contains "{browser_name}"'],
                    capture_output=True, text=True, timeout=2
                )
                if "true" not in running.stdout.lower():
                    continue
                # Check if any media is actually playing
                playing = subprocess.run(
                    ["osascript", "-e", check_script],
                    capture_output=True, text=True, timeout=2
                )
                if "true" not in playing.stdout.lower():
                    continue
                # Media is playing - pause it
                subprocess.run(
                    ["osascript", "-e", pause_script],
                    capture_output=True, timeout=2
                )
                state["paused_browsers"].append(browser_name)
                log(f"Paused browser media: {browser_name}")
            except Exception:
                pass

        return state

    def _restore_audio(self, state: dict | None) -> None:
        """Resume media that was paused before speaking."""
        if not state:
            return

        # Resume specific apps we paused
        resume_scripts = {
            "Music": 'tell application "Music" to play',
            "Spotify": 'tell application "Spotify" to play',
        }
        for app_name in state.get("paused_apps", []):
            if app_name in resume_scripts:
                try:
                    subprocess.run(
                        ["osascript", "-e", resume_scripts[app_name]],
                        capture_output=True, timeout=2
                    )
                    log(f"Resumed {app_name}")
                except Exception:
                    pass

        # Resume browser media we paused
        browser_resume = {
            "Arc": 'tell application "Arc" to tell front window to tell active tab to execute javascript "document.querySelectorAll(\\"video, audio\\").forEach(m => m.play())"',
            "Google Chrome": 'tell application "Google Chrome" to execute active tab of front window javascript "document.querySelectorAll(\\"video, audio\\").forEach(m => m.play())"',
            "Safari": 'tell application "Safari" to do JavaScript "document.querySelectorAll(\\"video, audio\\").forEach(m => m.play())" in front document',
        }
        for browser_name in state.get("paused_browsers", []):
            if browser_name in browser_resume:
                try:
                    subprocess.run(
                        ["osascript", "-e", browser_resume[browser_name]],
                        capture_output=True, timeout=2
                    )
                    log(f"Resumed browser media: {browser_name}")
                except Exception:
                    pass

    def _play_audio(self, audio_np: np.ndarray) -> None:
        """Play audio through sounddevice, with retry on device errors."""
        # Normalize audio to consistent level without distortion
        peak = np.max(np.abs(audio_np))
        if peak > 0:
            amplified = (audio_np / peak * 0.9).astype(np.float32)
        else:
            amplified = audio_np

        max_retries = 3
        for attempt in range(max_retries):
            try:
                sd.play(amplified, samplerate=24000)

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

            duck_state = None
            try:
                # Duck or pause other audio before speaking
                duck_state = await loop.run_in_executor(None, self._duck_audio)

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
                # Restore media playback and volume
                await loop.run_in_executor(None, self._restore_audio, duck_state)
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

    @staticmethod
    def _auto_name_from_text(text: str) -> str:
        """Derive a 2-4 word session name from message text."""
        # Common filler words to skip
        stop_words = {
            "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for",
            "of", "with", "by", "from", "is", "are", "was", "were", "been", "be",
            "has", "had", "have", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "shall", "can", "this", "that", "these",
            "those", "i", "you", "we", "they", "it", "he", "she", "my", "your",
            "our", "their", "its", "all", "just", "also", "now", "then", "here",
            "there", "up", "out", "so", "not", "no", "if", "as", "into", "about",
            "which", "when", "what", "how", "who", "where", "some", "any", "each",
            "every", "both", "more", "most", "very", "much", "many", "well",
            "still", "already", "yet", "too", "only", "new", "old",
        }

        # Clean text: take first sentence, strip markdown/special chars
        first_sentence = re.split(r'[.!?\n]', text)[0].strip()
        words = re.findall(r'[a-zA-Z]+', first_sentence)

        # Filter to meaningful words
        meaningful = [w for w in words if w.lower() not in stop_words and len(w) > 2]

        if not meaningful:
            return ""

        # Take first 3 meaningful words, title case
        name = " ".join(w.capitalize() for w in meaningful[:3])
        return name

    def _handle_speak(self, msg: dict[str, Any]) -> dict[str, Any]:
        text = msg.get("text", "")
        if not text:
            return {"error": "missing text field"}

        session = msg.get("session", "unknown")

        # Auto-name and auto-assign voice to new sessions
        if session != "unknown":
            changed = False
            if session not in self.config.session_names:
                auto_name = self._auto_name_from_text(text)
                if auto_name:
                    self.config.session_names[session] = auto_name
                    log(f"Auto-named session [{session}] as '{auto_name}'")
                    changed = True
            if session not in self.config.voice_map:
                used_voices = set(self.config.voice_map.values())
                for voice in AUTO_ASSIGN_VOICES:
                    if voice not in used_voices:
                        self.config.voice_map[session] = voice
                        display = self.config.session_names.get(session, session)
                        log(f"Auto-assigned voice '{voice}' to [{display}]")
                        changed = True
                        break
            if changed:
                self.config.save()

        # Store full_text for later read_full command
        full_text = msg.get("full_text")
        if full_text:
            self.last_full_text = full_text

        self.queue.put_nowait({
            "text": text,
            "session": session,
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
