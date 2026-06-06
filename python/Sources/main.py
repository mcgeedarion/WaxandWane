#!/usr/bin/env python3
"""
python/Sources/main.py  –  reference / developer script

Reads webcam frames to estimate ambient light and adjusts macOS keyboard
and screen brightness accordingly.

For production use, prefer the native Swift binary in swift/.

Dependencies:
    pip install opencv-python numpy

Keyboard backend (install one):
    brew install kbrightness
    brew tap rakalex/mac-brightnessctl && brew install mac-brightnessctl

Screen backend (install one):
    brew install brightness
    brew install ddcctl

macOS Camera Permission:
    System Settings → Privacy & Security → Camera → grant Terminal/IDE access

Config file (JSON, all keys optional):
    {
      "poll_interval_sec": 2.0,
      "smoothing_window": 5,
      "camera_index": 0,
      "capture_frames": 3,
      "change_threshold": 0.02,
      "keyboard_min": 0.0,
      "keyboard_max": 1.0,
      "invert_keyboard": false,
      "keyboard_control": "auto",
      "manual_keyboard_brightness": 0.5,
      "screen_min": 0.2,
      "screen_max": 1.0,
      "invert_screen": false,
      "screen_control": "auto",
      "manual_screen_brightness": 0.7,
      "default_keyboard_brightness": 0.5,
      "default_screen_brightness": 0.7,
      "max_runtime_sec": 3600.0,
      "reminder_interval_sec": 900.0
    }
"""

import argparse
import json
import subprocess
import time
import logging
import sys
from dataclasses import dataclass, asdict
from collections import deque
from typing import Callable, Optional, List, Tuple
import os
import shutil

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)



@dataclass
class Settings:
    poll_interval_sec: float = 2.0
    smoothing_window: int = 5
    camera_index: int = 0
    capture_frames: int = 3
    change_threshold: float = 0.02
    rise_threshold: Optional[float] = None
    fall_threshold: Optional[float] = None
    min_update_interval_sec: float = 0.0

    ambient_dark: float = 0.0
    ambient_bright: float = 1.0
    output_gamma: float = 1.0

    keyboard_min: float = 0.0
    keyboard_max: float = 1.0
    invert_keyboard: bool = False
    keyboard_control: str = "auto"
    manual_keyboard_brightness: float = 0.5
    keyboard_backend: Optional[str] = None

    screen_min: float = 0.2
    screen_max: float = 1.0
    invert_screen: bool = False
    screen_control: str = "auto"
    manual_screen_brightness: float = 0.7
    screen_backend: Optional[str] = None

    default_keyboard_brightness: float = 0.5
    default_screen_brightness: float = 0.7
    restore_original_brightness: bool = True
    dry_run: bool = False

    max_runtime_sec: float = 3600.0
    reminder_interval_sec: float = 900.0


def _load_config(path: str) -> dict:
    """Load a JSON config file and return its contents as a dict."""
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError(f"Config file must be a JSON object, got {type(data).__name__}")
    unknown = set(data) - set(asdict(Settings()).keys())
    if unknown:
        log.warning("Unknown config keys (ignored): %s", ", ".join(sorted(unknown)))
    return data



def validate_settings(s: Settings) -> None:
    def check(condition: bool, message: str) -> None:
        if not condition:
            raise ValueError(message)

    def unit(value: float, name: str) -> None:
        check(0.0 <= value <= 1.0, f"{name} must be in [0, 1]")

    check(s.poll_interval_sec > 0, "poll_interval_sec must be > 0")
    check(s.smoothing_window > 0, "smoothing_window must be > 0")
    check(s.camera_index >= 0, "camera_index must be >= 0")
    check(s.capture_frames > 0, "capture_frames must be > 0")
    check(s.change_threshold >= 0, "change_threshold must be >= 0")
    if s.rise_threshold is not None:
        check(s.rise_threshold >= 0, "rise_threshold must be >= 0")
    if s.fall_threshold is not None:
        check(s.fall_threshold >= 0, "fall_threshold must be >= 0")
    check(s.min_update_interval_sec >= 0, "min_update_interval_sec must be >= 0")
    unit(s.ambient_dark, "ambient_dark")
    unit(s.ambient_bright, "ambient_bright")
    check(s.ambient_bright > s.ambient_dark, "ambient_bright must be greater than ambient_dark")
    check(s.output_gamma > 0, "output_gamma must be > 0")
    unit(s.keyboard_min, "keyboard_min")
    unit(s.keyboard_max, "keyboard_max")
    check(s.keyboard_min <= s.keyboard_max, "keyboard_min must be <= keyboard_max")
    unit(s.manual_keyboard_brightness, "manual_keyboard_brightness")
    unit(s.default_keyboard_brightness, "default_keyboard_brightness")
    unit(s.screen_min, "screen_min")
    unit(s.screen_max, "screen_max")
    check(s.screen_min <= s.screen_max, "screen_min must be <= screen_max")
    unit(s.manual_screen_brightness, "manual_screen_brightness")
    unit(s.default_screen_brightness, "default_screen_brightness")
    check(s.keyboard_control in {"auto", "manual", "system"}, "keyboard_control must be one of: auto, manual, system")
    check(s.screen_control in {"auto", "manual", "system"}, "screen_control must be one of: auto, manual, system")
    check(s.max_runtime_sec >= 0, "max_runtime_sec must be >= 0")
    check(s.reminder_interval_sec >= 0, "reminder_interval_sec must be >= 0")


def default_config_json() -> str:
    return json.dumps(asdict(Settings()), indent=2, sort_keys=True)

def _build_settings(args: argparse.Namespace) -> Settings:
    """Merge JSON config (if given) with CLI overrides into a Settings object.

    Priority: CLI flags > JSON config > built-in defaults.
    """
    s = Settings()

    if args.config:
        cfg = _load_config(args.config)
        for key, value in cfg.items():
            if hasattr(s, key):
                current = getattr(s, key)
                if current is None:
                    setattr(s, key, value)
                elif isinstance(current, bool):
                    setattr(s, key, bool(value))
                else:
                    setattr(s, key, type(current)(value))

    cli = vars(args)
    for key, value in cli.items():
        if key == "config" or value is None:
            continue
        if hasattr(s, key):
            setattr(s, key, value)

    validate_settings(s)
    return s


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Wax and Wane – ambient-light keyboard/screen brightness daemon",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--config", metavar="PATH",
                   help="JSON config file (CLI flags override)")
    p.add_argument("--poll-interval",   dest="poll_interval_sec",   type=float, default=None,
                   metavar="SEC",        help="Seconds between brightness updates")
    p.add_argument("--smoothing-window",dest="smoothing_window",    type=int,   default=None,
                   metavar="N",          help="Number of samples to average")
    p.add_argument("--camera-index",    dest="camera_index",        type=int,   default=None,
                   metavar="N",          help="OpenCV camera index")
    p.add_argument("--capture-frames",  dest="capture_frames",      type=int,   default=None,
                   metavar="N",          help="Frames to grab per poll")
    p.add_argument("--change-threshold",dest="change_threshold",    type=float, default=None,
                   metavar="0-1",        help="Minimum brightness delta to trigger update")
    p.add_argument("--rise-threshold",  dest="rise_threshold",      type=float, default=None,
                   metavar="0-1",        help="Brightness increase delta threshold")
    p.add_argument("--fall-threshold",  dest="fall_threshold",      type=float, default=None,
                   metavar="0-1",        help="Brightness decrease delta threshold")
    p.add_argument("--min-update-interval", dest="min_update_interval_sec", type=float, default=None,
                   metavar="SEC",        help="Minimum seconds between backend writes")
    p.add_argument("--ambient-dark",    dest="ambient_dark",        type=float, default=None, metavar="0-1")
    p.add_argument("--ambient-bright",  dest="ambient_bright",      type=float, default=None, metavar="0-1")
    p.add_argument("--output-gamma",    dest="output_gamma",        type=float, default=None)
    p.add_argument("--keyboard-min",    dest="keyboard_min",        type=float, default=None,
                   metavar="0-1")
    p.add_argument("--keyboard-max",    dest="keyboard_max",        type=float, default=None,
                   metavar="0-1")
    p.add_argument("--keyboard-control", dest="keyboard_control", choices=("auto", "manual", "system"),
                   default=None, help="Keyboard mode: ambient auto, fixed manual, or leave to system")
    p.add_argument("--manual-keyboard", dest="manual_keyboard_brightness", type=float, default=None,
                   metavar="0-1", help="Fixed keyboard brightness when --keyboard-control=manual")
    p.add_argument("--keyboard-backend", dest="keyboard_backend", default=None,
                   help="Preferred keyboard backend name")
    p.add_argument("--invert-keyboard", dest="invert_keyboard",     type=lambda x: x.lower() != "false",
                   default=None,         metavar="true|false",
                   help="Invert keyboard mapping (bright→dark)")
    p.add_argument("--screen-min",      dest="screen_min",          type=float, default=None,
                   metavar="0-1")
    p.add_argument("--screen-max",      dest="screen_max",          type=float, default=None,
                   metavar="0-1")
    p.add_argument("--screen-control", dest="screen_control", choices=("auto", "manual", "system"),
                   default=None, help="Screen mode: ambient auto, fixed manual, or leave to system")
    p.add_argument("--manual-screen", dest="manual_screen_brightness", type=float, default=None,
                   metavar="0-1", help="Fixed screen brightness when --screen-control=manual")
    p.add_argument("--screen-backend", dest="screen_backend", default=None,
                   help="Preferred screen backend name")
    p.add_argument("--invert-screen",   dest="invert_screen",       type=lambda x: x.lower() != "false",
                   default=None,         metavar="true|false")
    p.add_argument("--default-keyboard",dest="default_keyboard_brightness", type=float, default=None,
                   metavar="0-1",        help="Keyboard brightness restored on exit")
    p.add_argument("--default-screen",  dest="default_screen_brightness",   type=float, default=None,
                   metavar="0-1",        help="Screen brightness restored on exit")
    p.add_argument("--dry-run",         dest="dry_run", action="store_true", default=None,
                   help="Print backend commands without changing brightness")
    p.add_argument("--restore-original-brightness", dest="restore_original_brightness", action="store_true", default=None)
    p.add_argument("--no-restore-original-brightness", dest="restore_original_brightness", action="store_false")
    p.add_argument("--max-runtime",     dest="max_runtime_sec",     type=float, default=None,
                   metavar="SEC",        help="Stop after this many seconds (0=unlimited)")
    p.add_argument("--print-default-config", action="store_true", help="Print a complete JSON config template and exit")
    p.add_argument("--doctor", action="store_true", help="Check backends and platform prerequisites, then exit")
    return p.parse_args()


DEFAULT_SETTINGS = Settings()



# SAFE_EXEC_DIRS is the canonical list; SAFE_ENV["PATH"] is the string form
# passed to shutil.which (which expects a colon-separated string, not a list).
SAFE_EXEC_DIRS = ("/usr/bin", "/usr/local/bin", "/opt/homebrew/bin")
SAFE_ENV = {"PATH": ":".join(SAFE_EXEC_DIRS), "HOME": os.path.expanduser("~")}
TRUSTED_CWD = os.path.expanduser("~")


def _resolve_executable(name: str) -> Optional[str]:
    """Resolve a helper name to an absolute path under SAFE_EXEC_DIRS only.

    Also validates the symlink target so a malicious symlink pointing outside
    the trusted directories cannot bypass the allowlist.
    """
    resolved = shutil.which(name, path=SAFE_ENV["PATH"])
    if not resolved:
        return None
    real = os.path.realpath(resolved)
    if any(
        real.startswith(prefix + os.sep) or real == prefix
        for prefix in SAFE_EXEC_DIRS
    ):
        return real
    log.warning("Ignoring unsafe executable path for %s: %s", name, real)
    return None



@dataclass
class BrightnessBackend:
    """Wraps a CLI tool that accepts a normalised [0, 1] brightness value."""
    name: str
    executable: str
    args_builder: Callable[[float], List[str]]
    out_min: float
    out_max: float
    read_builder: Optional[Callable[[], List[str]]] = None
    read_parser: Optional[Callable[[str], Optional[float]]] = None
    dry_run: bool = False

    def clamp(self, value: float) -> float:
        return float(min(max(value, self.out_min), self.out_max))

    def current_brightness(self) -> Optional[float]:
        if not self.read_builder or not self.read_parser:
            return None
        result = subprocess.run(
            [self.executable] + self.read_builder(),
            check=False,
            capture_output=True,
            text=True,
            cwd=TRUSTED_CWD,
            env=SAFE_ENV,
        )
        if result.returncode != 0:
            return None
        return self.read_parser(result.stdout)


def _parse_first_unit_float(text: str) -> Optional[float]:
    import re
    match = re.search(r"(?:0(?:\.\d+)?|1(?:\.0+)?)", text)
    return float(match.group(0)) if match else None


_KEYBOARD_CANDIDATES = [
    ("kbrightness",       lambda v: [f"{v:.3f}"],          None, None, 0.0, 1.0),
    ("mac-brightnessctl", lambda v: [str(int(v * 100))],   None, None, 0.0, 1.0),
]

_SCREEN_CANDIDATES = [
    ("brightness", lambda v: ["-l", f"{v:.3f}"],           lambda: ["-l"], _parse_first_unit_float, 0.0, 1.0),
    ("ddcctl",     lambda v: ["-b", str(int(v * 100))],    None, None, 0.0, 1.0),
]


def detect_backend(
    candidates: list,
    label: str,
    preferred_name: Optional[str] = None,
    dry_run: bool = False,
) -> Optional[BrightnessBackend]:
    """Return the first candidate whose executable resolves under SAFE_EXEC_DIRS."""
    filtered = [c for c in candidates if preferred_name is None or c[0] == preferred_name]
    if not filtered:
        log.warning("Unknown %s backend requested: %s", label, preferred_name)
        return None
    for name, builder, reader, parser, out_min, out_max in filtered:
        resolved = _resolve_executable(name)
        if resolved:
            log.info("Using %s backend: %s (%s)", label, name, resolved)
            return BrightnessBackend(
                name=name,
                executable=resolved,
                args_builder=builder,
                read_builder=reader,
                read_parser=parser,
                out_min=out_min,
                out_max=out_max,
                dry_run=dry_run,
            )
    log.warning("No %s backend found. %s control disabled.", label, label.capitalize())
    return None


def run_backend(backend: BrightnessBackend, value: float, label: str) -> None:
    clamped = backend.clamp(value)
    cmd = [backend.executable] + backend.args_builder(clamped)
    if backend.dry_run:
        log.info("[dry-run] %s", " ".join(cmd))
        return
    try:
        subprocess.run(
            cmd,
            check=True,
            capture_output=True,
            cwd=TRUSTED_CWD,
            env=SAFE_ENV,
        )
        log.debug("Set %s via %s → %.3f", label, backend.name, clamped)
    except subprocess.CalledProcessError as e:
        stderr = e.stderr.decode(errors="ignore").strip()
        log.warning("Failed to set %s via %s: %s", label, backend.name, stderr)



def normalize_ambient(ambient: float, dark: float, bright: float, gamma: float) -> float:
    linear = min(max((ambient - dark) / (bright - dark), 0.0), 1.0)
    return linear ** gamma


def map_ambient(ambient: float, out_min: float, out_max: float, invert: bool) -> float:
    if invert:
        return out_max - ambient * (out_max - out_min)
    return out_min + ambient * (out_max - out_min)


def _threshold_for_delta(delta: float, change_threshold: float, rise_threshold: Optional[float], fall_threshold: Optional[float]) -> float:
    if delta > 0:
        return change_threshold if rise_threshold is None else rise_threshold
    if delta < 0:
        return change_threshold if fall_threshold is None else fall_threshold
    return change_threshold


def target_for_control(
    control: str,
    smoothed_ambient: float,
    last_value: float,
    minimum: float,
    maximum: float,
    invert: bool,
    manual_value: float,
    change_threshold: float,
    rise_threshold: Optional[float] = None,
    fall_threshold: Optional[float] = None,
) -> Optional[float]:
    """Return the target for one brightness channel, or None if untouched."""
    if control == "system":
        return None
    if control == "manual":
        target = manual_value
    elif control == "auto":
        target = map_ambient(smoothed_ambient, minimum, maximum, invert)
    else:
        raise ValueError(f"Unsupported brightness control mode: {control}")

    delta = target - last_value
    threshold = _threshold_for_delta(delta, change_threshold, rise_threshold, fall_threshold)
    return target if abs(delta) > threshold else None


def compute_targets(
    history: deque,
    ambient_now: float,
    last_keyboard: float,
    last_screen: float,
    s: Settings,
) -> Tuple[Optional[float], Optional[float]]:
    """
    Return (new_keyboard, new_screen) or None for each if change is below
    threshold or that channel is left to system control. Pure – no I/O.
    """
    history.append(ambient_now)
    smoothed = sum(history) / len(history) if history else 0.0
    calibrated = normalize_ambient(smoothed, s.ambient_dark, s.ambient_bright, s.output_gamma)

    new_kbd = target_for_control(
        s.keyboard_control,
        calibrated,
        last_keyboard,
        s.keyboard_min,
        s.keyboard_max,
        s.invert_keyboard,
        s.manual_keyboard_brightness,
        s.change_threshold,
        s.rise_threshold,
        s.fall_threshold,
    )
    new_scr = target_for_control(
        s.screen_control,
        calibrated,
        last_screen,
        s.screen_min,
        s.screen_max,
        s.invert_screen,
        s.manual_screen_brightness,
        s.change_threshold,
        s.rise_threshold,
        s.fall_threshold,
    )
    return new_kbd, new_scr



class RuntimeGuard:
    """Centralises camera-runtime reminders and optional auto-stop."""

    def __init__(self, s: Settings) -> None:
        self._max    = s.max_runtime_sec
        self._remind = s.reminder_interval_sec
        self._start  = time.monotonic()
        self._last_reminder = self._start

    def should_exit(self) -> bool:
        return self._max > 0 and (time.monotonic() - self._start) >= self._max

    def maybe_remind(self) -> None:
        if self._remind <= 0:
            return
        now = time.monotonic()
        if now - self._last_reminder >= self._remind:
            log.info(
                "[Reminder] Wax and Wane is using the camera. "
                "Press Ctrl+C to stop."
            )
            self._last_reminder = now



def capture_mean_brightness(cap, n_frames: int = 3) -> float:
    """Average luma across n_frames. No inter-frame sleep — callers throttle
    via poll_interval_sec instead."""
    import cv2
    import numpy as np
    values = []
    for _ in range(n_frames):
        ret, frame = cap.read()
        if not ret:
            continue
        small = cv2.resize(frame, (64, 48))
        hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
        values.append(float(np.mean(hsv[:, :, 2]) / 255.0))
    return float(np.mean(values)) if values else 0.5



def doctor() -> None:
    log.info("Wax and Wane doctor")
    log.info("Safe executable directories: %s", ", ".join(SAFE_EXEC_DIRS))
    for label, candidates in (("keyboard", _KEYBOARD_CANDIDATES), ("screen", _SCREEN_CANDIDATES)):
        log.info("%s backends:", label.capitalize())
        for name, *_ in candidates:
            resolved = _resolve_executable(name)
            log.info("  %s %s", "✓" if resolved else "✗", f"{name}: {resolved or 'not found'}")
    import importlib.util
    log.info("OpenCV import: %s", "available" if importlib.util.find_spec("cv2") else "unavailable")


def main_loop(s: Settings = DEFAULT_SETTINGS) -> None:
    import cv2
    validate_settings(s)
    keyboard_enabled = s.keyboard_control != "system"
    screen_enabled = s.screen_control != "system"
    keyboard_backend = (
        detect_backend(_KEYBOARD_CANDIDATES, "keyboard", s.keyboard_backend, s.dry_run) if keyboard_enabled else None
    )
    screen_backend = detect_backend(_SCREEN_CANDIDATES, "screen", s.screen_backend, s.dry_run) if screen_enabled else None

    if not keyboard_enabled and not screen_enabled:
        log.error("Keyboard and screen are both set to system control; nothing to adjust.")
        sys.exit(1)

    if (keyboard_enabled and keyboard_backend is None) and (screen_enabled and screen_backend is None):
        log.error("No enabled output backends available. Install a backend or set that channel to system control.")
        sys.exit(1)

    cap = cv2.VideoCapture(s.camera_index)
    if not cap.isOpened():
        log.error(
            "Cannot open webcam. Check camera permissions in "
            "System Settings → Privacy & Security → Camera."
        )
        sys.exit(1)

    log.info("Camera active. Warming up auto-exposure (3 s)…")
    for _ in range(15):
        cap.read()
        time.sleep(0.2)

    original_keyboard = keyboard_backend.current_brightness() if keyboard_backend and s.restore_original_brightness else None
    original_screen = screen_backend.current_brightness() if screen_backend and s.restore_original_brightness else None

    history: deque = deque(maxlen=s.smoothing_window)
    last_keyboard = original_keyboard if original_keyboard is not None else -1.0
    last_screen   = original_screen if original_screen is not None else -1.0
    last_write = 0.0
    guard = RuntimeGuard(s)

    def restore_defaults() -> None:
        if keyboard_backend and s.keyboard_control != "system":
            run_backend(keyboard_backend, original_keyboard if original_keyboard is not None else s.default_keyboard_brightness, "keyboard brightness")
        if screen_backend and s.screen_control != "system":
            run_backend(screen_backend, original_screen if original_screen is not None else s.default_screen_brightness, "screen brightness")

    log.info("Ambient loop started. Ctrl+C to stop.")
    try:
        while True:
            if guard.should_exit():
                log.info("Max runtime reached. Stopping.")
                break
            guard.maybe_remind()

            ambient = capture_mean_brightness(cap, s.capture_frames)
            new_kbd, new_scr = compute_targets(
                history, ambient, last_keyboard, last_screen, s
            )

            may_write = (time.monotonic() - last_write) >= s.min_update_interval_sec
            if may_write and new_kbd is not None and keyboard_backend:
                run_backend(keyboard_backend, new_kbd, "keyboard brightness")
                last_keyboard = new_kbd
                last_write = time.monotonic()

            if may_write and new_scr is not None and screen_backend:
                run_backend(screen_backend, new_scr, "screen brightness")
                last_screen = new_scr
                last_write = time.monotonic()

            smoothed = sum(history) / len(history) if history else ambient
            calibrated = normalize_ambient(smoothed, s.ambient_dark, s.ambient_bright, s.output_gamma)
            log.info(
                "Ambient: %.3f (calibrated %.3f) → Keyboard: %s | Screen: %s",
                smoothed,
                calibrated,
                "system" if s.keyboard_control == "system" else f"{last_keyboard:.3f}",
                "system" if s.screen_control == "system" else f"{last_screen:.3f}",
            )

            time.sleep(s.poll_interval_sec)

    except KeyboardInterrupt:
        log.info("Interrupted. Restoring defaults.")
    finally:
        restore_defaults()
        cap.release()


_map_value = map_ambient
run = main_loop


if __name__ == "__main__":
    args = _parse_args()
    if getattr(args, "print_default_config", False):
        print(default_config_json())
    elif getattr(args, "doctor", False):
        doctor()
    else:
        main_loop(_build_settings(args))
