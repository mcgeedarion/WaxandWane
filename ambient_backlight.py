#!/usr/bin/env python3
"""Compatibility launcher for the Python AutoKeyboardDim implementation.

The canonical Python source now mirrors the Swift layout at
``python/Sources/main.py``. Keep this wrapper so existing commands that run
``python3 ambient_backlight.py`` continue to work.
"""

from python.Sources.main import _build_settings, _parse_args, run


if __name__ == "__main__":
    run(_build_settings(_parse_args()))
