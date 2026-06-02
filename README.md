# AutoKeyboardDim

Automatically adjusts macOS keyboard backlight and display brightness based
on ambient light estimated from the built-in webcam.

## Implementations

| Path | Language | Recommended use |
|---|---|---|
| `swift/` | Swift (native) | **Primary — use this for daily use / LaunchAgent** |
| `python/` | Python | Reference / developer implementation mirroring the Swift layout |
| `ambient_backlight.py` | Python | Compatibility launcher for existing scripts |

Both share the same algorithm, security model, and mirrored source layout (`Sources/main.*` plus `Tests/PolicyTests.*`) where language conventions allow. Prefer the Swift binary
for production because it uses AVFoundation natively (no pip dependencies,
no OpenCV), integrates with Notification Center, and compiles to a standalone
executable.

## Cross-language Layout

The Python and Swift implementations intentionally use matching file and test
names where practical:

| Concern | Swift | Python |
|---|---|---|
| Main entry point | `swift/Sources/main.swift` | `python/Sources/main.py` |
| Policy tests | `swift/Tests/PolicyTests.swift` | `python/Tests/PolicyTests.py` |
| Compatibility launcher | N/A | `ambient_backlight.py` |

Core policy symbols also use matching names adapted to language style, such as
`mapAmbient` in Swift and `map_ambient` in Python, with `ComputeTargetsTests`
and `MapAmbientTests` in both test suites.

## How It Works

1. **Webcam → ambient light**: Samples camera frames, extracts luma (Y plane
   in Swift, HSV-V in Python), averages across a rolling window.
2. **Policy mapping**: Independently maps the smoothed ambient value to keyboard
   and/or screen brightness with configurable min/max and optional inversion.
   Each channel can also be fixed manually or left to system control.
3. **Threshold guard**: Only writes when brightness changes by > 2% to avoid
   constant subprocess churn.
4. **Privacy guard**: Sends a Notification Center banner on start and
   periodic reminders while the camera is active. Optionally auto-stops
   after a configurable runtime limit.
5. **CLI backends**: Shells out to `kbrightness`/`mac-brightnessctl` (keyboard)
   and `brightness`/`ddcctl` (screen). Executable paths are resolved at
   startup and validated against an allow-list of safe directories.

## Security Model

- **No PATH hijacking**: helper executables are resolved once at startup via
  an allow-list (`/usr/bin`, `/usr/local/bin`, `/opt/homebrew/bin`). The
  resolved absolute path is stored and used for all subsequent invocations.
- **Sanitized subprocess environment**: child processes receive only a
  minimal, fixed environment (`PATH`, `HOME`, locale). `LD_PRELOAD`,
  `DYLD_INSERT_LIBRARIES`, and `PYTHONPATH` are explicitly stripped.
- **Trusted CWD**: subprocesses are always launched with `cwd` set to `$HOME`.
- **No shell expansion**: all commands are passed as argument arrays, never
  through a shell, so there is no command-injection surface.
- **Camera privacy**: Notification Center banner on start and configurable
  periodic reminders. Optional auto-stop (`maxCameraRuntimeSeconds`).

## Requirements

### Swift binary (recommended)
- macOS 13 (Ventura) or later
- Swift toolchain (`xcode-select --install` or Xcode)

### Python script
- Python 3.8+
- `pip install opencv-python numpy`

## Brightness Backends

### Keyboard (install one)

```bash
# Option 1 — kbrightness
brew install kbrightness

# Option 2 — mac-brightnessctl
brew tap rakalex/mac-brightnessctl
brew install mac-brightnessctl
```

### Screen (install one)

```bash
# Option 1 — brightness (built-in display)
brew install brightness

# Option 2 — ddcctl (external DDC display)
brew install ddcctl
```

## Camera Permission

Grant your terminal / app camera access:
**System Settings → Privacy & Security → Camera**

## Usage

### Swift (recommended)

```bash
cd swift
swift build -c release
.build/release/AmbientBacklight
```

Press `Ctrl+C` to stop. Channels controlled by AutoKeyboardDim restore to defaults.

Run only one channel manually while leaving the other under system control:

```bash
# Fix display brightness and leave keyboard backlight untouched.
.build/release/AmbientBacklight --screen-control manual --manual-screen 0.7 --keyboard-control system

# Fix keyboard backlight and leave display brightness untouched.
.build/release/AmbientBacklight --keyboard-control manual --manual-keyboard 0.4 --screen-control system
```

### Python (script / dev)

```bash
pip install opencv-python numpy
python3 ambient_backlight.py
# or run the canonical mirrored entry point directly:
python3 python/Sources/main.py
```

### Configuration

Edit the `Settings` struct in `swift/Sources/main.swift` (or the `Settings`
dataclass in `python/Sources/main.py`):

| Field | Default | Description |
|---|---|---|
| `pollIntervalSeconds` / `poll_interval_sec` | `2.0` | Seconds between samples |
| `smoothingWindow` / `smoothing_window` | `5` | Rolling-average window size |
| `changeThreshold` / `change_threshold` | `0.02` | Min brightness delta to trigger a write |
| `keyboardMin/Max` / `keyboard_min/max` | `0.0 / 1.0` | Keyboard output range |
| `screenMin/Max` / `screen_min/max` | `0.2 / 1.0` | Screen output range |
| `invertKeyboard` / `invert_keyboard` | `false` | Dark room → dimmer keyboard |
| `keyboardControl` / `keyboard_control` | `auto` | Keyboard mode: `auto`, `manual`, or `system` |
| `manualKeyboardBrightness` / `manual_keyboard_brightness` | `0.5` | Fixed keyboard brightness for manual mode |
| `invertScreen` / `invert_screen` | `false` | Dark room → dimmer screen |
| `screenControl` / `screen_control` | `auto` | Screen mode: `auto`, `manual`, or `system` |
| `manualScreenBrightness` / `manual_screen_brightness` | `0.7` | Fixed screen brightness for manual mode |
| `maxCameraRuntimeSeconds` / `max_runtime_sec` | `3600` | Auto-stop after N seconds (0 = unlimited) |
| `reminderIntervalSeconds` / `reminder_interval_sec` | `900` | Notification reminder cadence (0 = off) |

## Run as a Background Service (LaunchAgent)

1. Build the Swift binary: `cd swift && swift build -c release`
2. Edit `com.user.ambientbacklight.plist` — set the `ProgramArguments` path
   to the compiled binary, e.g. `/Users/you/AutoKeyboardDim/swift/.build/release/AmbientBacklight`.
3. Install and load:

```bash
cp com.user.ambientbacklight.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.ambientbacklight.plist
```

To stop:

```bash
launchctl unload ~/Library/LaunchAgents/com.user.ambientbacklight.plist
```
