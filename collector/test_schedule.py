#!/usr/bin/env python3
"""Clock-aligned polling tests. No HomeKit accessories or secrets required."""

from __future__ import annotations

import sys
import types
import unittest
from datetime import datetime, timezone
from pathlib import Path


def _install_homekit_stub() -> None:
    if "homekit.controller" in sys.modules:
        return

    homekit = types.ModuleType("homekit")
    controller = types.ModuleType("homekit.controller")
    model = types.ModuleType("homekit.model")
    characteristics = types.ModuleType("homekit.model.characteristics")

    class CharacteristicsTypes:
        TEMPERATURE_CURRENT = "temperature"
        RELATIVE_HUMIDITY_CURRENT = "humidity"

        @staticmethod
        def get_uuid(value: str) -> str:
            return value

    characteristics.CharacteristicsTypes = CharacteristicsTypes
    controller.Controller = object
    homekit.controller = controller
    homekit.model = model
    model.characteristics = characteristics

    sys.modules["homekit"] = homekit
    sys.modules["homekit.controller"] = controller
    sys.modules["homekit.model"] = model
    sys.modules["homekit.model.characteristics"] = characteristics


sys.path.insert(0, str(Path(__file__).resolve().parent))
_install_homekit_stub()

from app import next_aligned_datetime, seconds_until_next_aligned_slot  # noqa: E402

INTERVAL = 600
UTC = timezone.utc


def utc(*parts: int) -> datetime:
    return datetime(*parts, tzinfo=UTC)


class ClockAlignedScheduleTests(unittest.TestCase):
    def test_start_mid_slot_waits_for_next_boundary(self) -> None:
        now = utc(2026, 9, 19, 17, 37, 42)
        self.assertEqual(next_aligned_datetime(now, INTERVAL), utc(2026, 9, 19, 17, 40, 0))

    def test_exact_slot_uses_the_following_slot(self) -> None:
        now = utc(2026, 9, 19, 17, 40, 0)
        self.assertEqual(next_aligned_datetime(now, INTERVAL), utc(2026, 9, 19, 17, 50, 0))

    def test_hour_boundary(self) -> None:
        now = utc(2026, 9, 19, 17, 59, 59)
        self.assertEqual(next_aligned_datetime(now, INTERVAL), utc(2026, 9, 19, 18, 0, 0))

    def test_midnight_boundary(self) -> None:
        now = utc(2026, 9, 19, 23, 59, 59)
        self.assertEqual(next_aligned_datetime(now, INTERVAL), utc(2026, 9, 20, 0, 0, 0))

    def test_overrun_skips_missed_slot_without_catch_up(self) -> None:
        # Collection started at 17:40 and finished after 17:50.
        finished = utc(2026, 9, 19, 17, 51, 3)
        nxt = next_aligned_datetime(finished, INTERVAL)
        self.assertEqual(nxt, utc(2026, 9, 19, 18, 0, 0))
        self.assertNotEqual(nxt, utc(2026, 9, 19, 17, 50, 0))
        self.assertGreater(seconds_until_next_aligned_slot(finished, INTERVAL), 0)

    def test_wait_is_the_remaining_seconds_not_a_full_interval(self) -> None:
        now = utc(2026, 9, 19, 17, 37, 42)
        self.assertEqual(seconds_until_next_aligned_slot(now, INTERVAL), 138.0)


if __name__ == "__main__":
    unittest.main()
