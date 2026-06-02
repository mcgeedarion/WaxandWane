"""Unit tests for pure policy functions in python/Sources/main.py.

Run with:  python -m pytest python/Tests
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(__file__))))

from collections import deque
import pytest
from python.Sources.main import map_ambient, compute_targets, Settings


# ---------------------------------------------------------------------------
# map_ambient
# ---------------------------------------------------------------------------

class MapAmbientTests:
    def test_no_invert_min(self):
        assert map_ambient(0.0, 0.2, 1.0, invert=False) == pytest.approx(0.2)

    def test_no_invert_max(self):
        assert map_ambient(1.0, 0.2, 1.0, invert=False) == pytest.approx(1.0)

    def test_no_invert_mid(self):
        assert map_ambient(0.5, 0.0, 1.0, invert=False) == pytest.approx(0.5)

    def test_invert_min(self):
        # ambient=0, invert=True → max output (inverted mapping, not the default)
        assert map_ambient(0.0, 0.0, 1.0, invert=True) == pytest.approx(1.0)

    def test_invert_max(self):
        assert map_ambient(1.0, 0.0, 1.0, invert=True) == pytest.approx(0.0)

    def test_invert_mid(self):
        assert map_ambient(0.5, 0.0, 1.0, invert=True) == pytest.approx(0.5)

    def test_clamping_not_done_here(self):
        # map_ambient is a pure linear map; clamping is the backend's job
        result = map_ambient(2.0, 0.0, 1.0, invert=False)
        assert result == pytest.approx(2.0)


# ---------------------------------------------------------------------------
# compute_targets
# ---------------------------------------------------------------------------

def _default_settings(**overrides) -> Settings:
    s = Settings()
    for k, v in overrides.items():
        setattr(s, k, v)
    return s


class ComputeTargetsTests:
    def _history(self, window: int = 5) -> deque:
        return deque(maxlen=window)

    def test_first_sample_always_triggers(self):
        h = self._history()
        s = _default_settings(change_threshold=0.02)
        kbd, scr = compute_targets(h, 0.5, last_keyboard=-1.0, last_screen=-1.0, s=s)
        assert kbd is not None
        assert scr is not None

    def test_no_change_below_threshold(self):
        h = self._history()
        s = _default_settings(change_threshold=0.05)
        # Prime history
        compute_targets(h, 0.5, -1.0, -1.0, s)
        # Second call with same ambient → computed targets barely change
        kbd, scr = compute_targets(h, 0.5, 0.5, 0.3, s)
        assert kbd is None  # delta < 0.05

    def test_change_above_threshold_triggers(self):
        h = self._history()
        s = _default_settings(change_threshold=0.02)
        compute_targets(h, 0.1, -1.0, -1.0, s)
        kbd, scr = compute_targets(h, 0.9, 0.1, 0.1, s)
        assert kbd is not None
        assert scr is not None

    def test_smoothing_damps_spike(self):
        """A single outlier frame should not immediately drive a large jump
        when the smoothing window is large."""
        h = self._history(window=5)
        s = _default_settings(change_threshold=0.02,
                               smoothing_window=5,
                               keyboard_min=0.0, keyboard_max=1.0,
                               invert_keyboard=False)
        # Fill window with 0.5
        for _ in range(5):
            compute_targets(h, 0.5, -1.0, -1.0, s)
        # Spike to 1.0; smoothed = (4*0.5 + 1.0) / 5 = 0.6
        kbd, _ = compute_targets(h, 1.0, 0.5, 0.5, s)
        if kbd is not None:
            assert abs(kbd - 0.5) < 0.2  # smoothed, not a full jump to 1.0

    def test_history_appended(self):
        h = self._history(window=3)
        s = _default_settings()
        compute_targets(h, 0.3, -1.0, -1.0, s)
        compute_targets(h, 0.6, 0.0, 0.0, s)
        assert len(h) == 2

    def test_keyboard_dark_room_dim(self):
        """With invert_keyboard=False (default), dark ambient (0.0) → keyboard_min."""
        h = self._history()
        s = _default_settings(invert_keyboard=False,
                               keyboard_min=0.0, keyboard_max=1.0,
                               change_threshold=0.0)
        kbd, _ = compute_targets(h, 0.0, -1.0, -1.0, s)
        assert kbd == pytest.approx(0.0)

    def test_keyboard_bright_room_bright(self):
        """With invert_keyboard=False (default), bright ambient (1.0) → keyboard_max."""
        h = self._history()
        s = _default_settings(invert_keyboard=False,
                               keyboard_min=0.0, keyboard_max=1.0,
                               change_threshold=0.0)
        kbd, _ = compute_targets(h, 1.0, -1.0, -1.0, s)
        assert kbd == pytest.approx(1.0)

    def test_screen_no_invert(self):
        """With invert_screen=False, bright ambient (1.0) → max screen."""
        h = self._history()
        s = _default_settings(invert_screen=False,
                               screen_min=0.2, screen_max=1.0,
                               change_threshold=0.0)
        _, scr = compute_targets(h, 1.0, -1.0, -1.0, s)
        assert scr == pytest.approx(1.0)
