# Security Review: Wax and Wane

Date: 2026-06-07

## Scope
- `python/Sources/main.py`
- `ambient_backlight.py` compatibility launcher
- `swift/Sources/WaxAndWaneCore/Backends.swift`
- `swift/Sources/WaxAndWaneCore/MacApp.swift`
- `swift/Sources/WaxAndWaneCore/Settings.swift`
- `swift/Sources/WaxAndWaneCore/CLI.swift`

## Findings

### 1) Backend helper process hang can block the daemon (Medium) — Fixed
The Python and Swift implementations launch local helper tools (`kbrightness`,
`mac-brightnessctl`, `brightness`, `ddcctl`) to read or write brightness. A
malfunctioning, compromised, or unexpectedly interactive helper could run
indefinitely. Because backend calls were synchronous and had no timeout, this
could stop camera-loop progress, prevent later brightness corrections, and delay
shutdown/restore behavior.

Mitigation implemented:
- Python backend reads and writes now use a bounded subprocess timeout and log a
  warning instead of propagating timeout exceptions.
- Swift backend process execution now enforces the same bounded timeout,
  terminates slow helpers, escalates to `SIGKILL` if needed, and reports timeout
  status to callers.
- Regression tests cover slow-helper timeout behavior in both implementations.

### 2) PATH hijacking of privileged helper binaries (Previously High) — Mitigated
Both implementations previously depended on ambient PATH lookup for helper
binaries. That can become arbitrary code execution if the program is run from a
LaunchAgent/daemon or privileged shell with attacker-influenced PATH.

Current mitigation:
- Helper names are selected from fixed candidate lists.
- Executables are resolved only from allow-listed directories:
  `/usr/bin`, `/usr/local/bin`, `/opt/homebrew/bin`.
- Symlink targets are resolved and must also remain under those directories.
- Backend invocations use the resolved absolute executable path.

Residual risk:
- The trusted directories themselves must retain normal system permissions.
  A user-writable directory in this allow-list would reintroduce the risk.

### 3) Untrusted child-process execution context (Previously Medium) — Mitigated
Backend helpers are launched from a trusted working directory and receive a
minimal environment. This avoids inheriting arbitrary current-directory context
and strips high-risk ambient variables such as dynamic-loader and language-path
settings.

### 4) Camera privacy exposure through continuous background capture (Low) — Mitigated
The app continuously samples the camera by design, which is privacy-sensitive
even though frames are only reduced to brightness estimates.

Current mitigation:
- Runtime logs indicate when the camera is active.
- A configurable maximum runtime stops the loop by default.
- Periodic reminders notify/log that camera capture is active.

## Notes
- No command-injection sink was found: helper commands are executed as argument
  arrays, not through a shell.
- No network-facing surface was identified in this codebase.
- Config files are parsed as JSON into typed settings and validated before use.
