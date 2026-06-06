# Wax and Wane

Automatically adjusts macOS keyboard backlight and display brightness based on ambient light estimated from the built-in webcam.

## Implementations

| Path | Language | Recommended use |
|---|---|---|
| `swift/` | Swift (native) | **Primary — daily use / LaunchAgent** |
| `python/` | Python | Reference / developer implementation mirroring the Swift policy |
| `ambient_backlight.py` | Python | Compatibility launcher for existing scripts |

The Swift binary uses AVFoundation natively, integrates with Notification Center, and builds to a standalone executable. The Python implementation is kept as a reference and testable mirror of the same policy decisions.

## What's improved

- **Config-first workflow**: generate a full JSON template with `wax-and-wane print-default-config`; see `examples/config.json`.
- **Strict validation**: brightness ranges, timing values, calibration bounds, and mode names are checked before the camera starts.
- **Original-brightness restore**: supported backends are queried at startup and restored on exit; configured defaults remain the fallback.
- **Calibration and hysteresis**: ambient samples can be normalized with dark/bright calibration points, gamma, separate rise/fall thresholds, and a minimum write interval.
- **Backend selection and diagnostics**: choose helpers with `--keyboard-backend` / `--screen-backend`, and run `wax-and-wane doctor` for setup checks.
- **Install and LaunchAgent workflow**: `make install` and `make launchagent-install` install the release binary, config, plist, and logs.
- **CI-ready layout**: Linux-safe Python checks and macOS Swift checks are defined in `.github/workflows/ci.yml`.
- **Modular Swift sources**: policy, settings, backends, CLI, and macOS camera loop are split across focused files.
- **Privacy controls**: startup/periodic reminders remain, and `--dry-run` previews decisions without changing brightness.

## How It Works

1. **Webcam → ambient light**: Samples camera frames, extracts luma (Y plane in Swift, HSV-V in Python), and averages across a rolling window.
2. **Calibration**: Normalizes smoothed ambient light between `ambientDark` and `ambientBright`, then applies `outputGamma`.
3. **Policy mapping**: Independently maps calibrated ambient light to keyboard and/or screen brightness with min/max, manual, system, and inversion controls.
4. **Hysteresis guards**: Applies delta thresholds, optional rise/fall thresholds, and an optional minimum write interval to reduce brightness oscillation.
5. **Privacy guard**: Sends a Notification Center banner on start and periodic reminders while the camera is active. Optional auto-stop is controlled by `maxCameraRuntimeSeconds`.
6. **CLI backends**: Shells out to `kbrightness`/`mac-brightnessctl` (keyboard) and `brightness`/`ddcctl` (screen). Executable paths are resolved at startup and validated against safe directories.

## Security Model

- **No PATH hijacking**: helper executables are resolved once at startup via an allow-list (`/usr/bin`, `/usr/local/bin`, `/opt/homebrew/bin`). The resolved absolute path is used for subsequent invocations.
- **Sanitized subprocess environment**: child processes receive a minimal fixed environment (`PATH`, `HOME`, locale). Dangerous dynamic-loader and Python path variables are not passed through.
- **Trusted CWD**: subprocesses are launched from `$HOME`.
- **No shell expansion**: commands are passed as argument arrays, never through a shell.
- **Camera privacy**: startup notification, periodic reminders, dry-run mode, and optional auto-stop.

## Requirements

### Swift binary (recommended)

- macOS 13 Ventura or later
- Swift toolchain (`xcode-select --install` or Xcode)

### Python script

- Python 3.8+
- `pip install opencv-python numpy`

## Brightness Backends

### Keyboard (install one)

```bash
brew install kbrightness
# or
brew tap rakalex/mac-brightnessctl
brew install mac-brightnessctl
```

### Screen (install one)

```bash
brew install brightness
# or, for some external DDC displays
brew install ddcctl
```

Run diagnostics after installing helpers:

```bash
wax-and-wane doctor
# or from source
cd swift && swift run --quiet wax-and-wane doctor
```

## Camera Permission

Grant your terminal or installed app camera access:
**System Settings → Privacy & Security → Camera**.

## Usage

### Swift (recommended)

```bash
cd swift
swift build -c release
.build/release/wax-and-wane run
```

Press `Ctrl+C` to stop. Channels controlled by Wax and Wane restore to the original startup brightness when supported, otherwise to configured defaults.

Run only one channel manually while leaving the other under system control:

```bash
.build/release/wax-and-wane run --screen-control manual --manual-screen 0.7 --keyboard-control system
.build/release/wax-and-wane run --keyboard-control manual --manual-keyboard 0.4 --screen-control system
```

Preview backend writes without changing brightness:

```bash
.build/release/wax-and-wane run --dry-run --max-runtime 30
```

### Python (script / dev)

```bash
pip install opencv-python numpy
python3 ambient_backlight.py
# or run the canonical mirrored entry point directly:
python3 python/Sources/main.py
```

Python diagnostics and config template commands:

```bash
python3 python/Sources/main.py --doctor
python3 python/Sources/main.py --print-default-config
```

## Configuration

Generate a complete config template:

```bash
wax-and-wane print-default-config > ~/.config/wax-and-wane/config.json
# or from source
cd swift && swift run --quiet wax-and-wane print-default-config > ../examples/config.generated.json
```

The Swift example is `examples/config.json`; the Python reference example is `examples/python-config.json`. CLI flags override JSON config, and JSON config overrides built-in defaults.

Key fields:

| Field | Default | Description |
|---|---:|---|
| `pollIntervalSeconds` / `poll_interval_sec` | `2.0` | Seconds between samples. |
| `smoothingWindow` / `smoothing_window` | `5` | Rolling-average sample count; must be positive. |
| `changeThreshold` / `change_threshold` | `0.02` | Default brightness delta required before writing. |
| `riseThreshold` / `rise_threshold` | `null` | Optional increase-specific threshold. |
| `fallThreshold` / `fall_threshold` | `null` | Optional decrease-specific threshold. |
| `minUpdateIntervalSeconds` / `min_update_interval_sec` | `0.0` | Minimum seconds between backend writes. |
| `ambientDark` / `ambient_dark` | `0.0` | Camera value representing room darkness. |
| `ambientBright` / `ambient_bright` | `1.0` | Camera value representing room brightness. |
| `outputGamma` / `output_gamma` | `1.0` | Non-linear response curve. |
| `keyboardBackend` / `keyboard_backend` | `null` | Optional helper name (`kbrightness`, `mac-brightnessctl`). |
| `screenBackend` / `screen_backend` | `null` | Optional helper name (`brightness`, `ddcctl`). |
| `restoreOriginalBrightness` / `restore_original_brightness` | `true` | Restore startup brightness where a backend can query it. |
| `dryRun` / `dry_run` | `false` | Log intended backend writes without applying them. |

### Calibration workflow

1. Sit in a dim room and run `--dry-run`; note the raw ambient value from logs.
2. Set `ambientDark` / `ambient_dark` to that dim-room value.
3. Sit in bright lighting and note the raw ambient value.
4. Set `ambientBright` / `ambient_bright` to that bright-room value.
5. Adjust `outputGamma`: values above `1.0` make low light less aggressive; values below `1.0` brighten earlier.

### Validate configuration before launch

```bash
cd swift && swift run --quiet wax-and-wane validate-config ../examples/config.json
# or after install
wax-and-wane validate-config ~/.config/wax-and-wane/config.json
```

## Install and run at login

Install the Swift release binary and create a default config if one does not exist:

```bash
make install
```

Install and load a LaunchAgent that runs at login:

```bash
make launchagent-install
```

The LaunchAgent is throttled and only automatically restarts after unsuccessful exits, which prevents tight crash loops from repeated configuration or permission failures.

Unload and remove the LaunchAgent:

```bash
make launchagent-uninstall
```

Uninstall the binary but keep user config:

```bash
make uninstall
```

The LaunchAgent template is `com.user.waxandwane.plist`; `make launchagent-install` fills in the installed binary path, config path, and log directory.

## Development

```bash
python3 -m pytest -q python/Tests
cd swift && swift test
make release
make dist
```

On Linux, the Swift executable builds only the non-camera diagnostic/config path. The actual camera loop requires macOS AVFoundation, so CI runs Swift build/test on macOS. `make release` runs release-mode tests and CLI smoke checks; `make dist` creates a checksum file for the release binary.
