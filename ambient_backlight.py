#!/usr/bin/env python3
"""Compatibility launcher for the Python Wax and Wane implementation.

The canonical Python source now mirrors the Swift layout at
``python/Sources/main.py``. Keep this wrapper so existing commands that run
``python3 ambient_backlight.py`` continue to work.
"""

from python.Sources.main import (
    _build_settings,
    _parse_args,
    default_config_json,
    doctor,
    run,
)


if __name__ == "__main__":
    args = _parse_args()
    if getattr(args, "print_default_config", False):
        print(default_config_json())
    elif getattr(args, "doctor", False):
        doctor()
    else:
        run(_build_settings(args))
