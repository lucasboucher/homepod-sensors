#!/usr/bin/env python3
"""Tests for the local rooms.json mapper. No real pairing files or secrets."""

from __future__ import annotations

import json
import stat
import sys
import tempfile
import types
import unittest
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
        NAME = "name"

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


COLLECTOR_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(COLLECTOR_DIR))
_install_homekit_stub()

from app import load_rooms_map, resolve_sensor_name  # noqa: E402
from homekit_room_mapper import (  # noqa: E402
    assign_rooms,
    build_rooms_mapping,
    confirm_overwrite,
    parse_room_choice,
    rooms_mapping_contains_secrets,
    write_rooms_file,
)


class RoomMapperTests(unittest.TestCase):
    def test_build_mapping_keeps_device_ids_and_rooms(self) -> None:
        mapping = build_rooms_mapping(
            [
                ("AA:BB:CC:00:00:01", "Salon"),
                (" aa:bb:cc:00:00:02 ", " Chambre "),
                ("", "Salon"),
                ("AA:BB:CC:00:00:03", "  "),
            ]
        )
        self.assertEqual(
            mapping,
            {
                "AA:BB:CC:00:00:01": "Salon",
                "aa:bb:cc:00:00:02": "Chambre",
            },
        )

    def test_write_refuses_existing_file_without_overwrite(self) -> None:
        path = Path(tempfile.mkdtemp()) / "rooms.json"
        write_rooms_file(str(path), {"AA:BB:CC:00:00:01": "Salon"}, overwrite=True)
        with self.assertRaises(FileExistsError):
            write_rooms_file(str(path), {"AA:BB:CC:00:00:02": "Chambre"}, overwrite=False)

    def test_confirm_overwrite_requires_explicit_yes(self) -> None:
        self.assertFalse(confirm_overwrite("/tmp/rooms.json", prompt_fn=lambda _: "n"))
        self.assertTrue(confirm_overwrite("/tmp/rooms.json", prompt_fn=lambda _: "y"))

    def test_written_file_mode_is_600_and_has_no_secrets(self) -> None:
        path = Path(tempfile.mkdtemp()) / "rooms.json"
        mapping = {
            "AA:BB:CC:00:00:01": "Salon",
            "AA:BB:CC:00:00:02": "Chambre",
        }
        write_rooms_file(str(path), mapping, overwrite=True)
        mode = stat.S_IMODE(path.stat().st_mode)
        self.assertEqual(mode, 0o600)
        payload = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(payload, mapping)
        self.assertFalse(rooms_mapping_contains_secrets(payload))
        dumped = path.read_text(encoding="utf-8")
        self.assertNotIn("AccessoryLTPK", dumped)
        self.assertNotIn("iOSDeviceLTSK", dumped)
        self.assertNotIn("iOSPairingId", dumped)

    def test_write_rejects_secret_fields(self) -> None:
        path = Path(tempfile.mkdtemp()) / "rooms.json"
        with self.assertRaises(ValueError):
            write_rooms_file(str(path), {"AccessoryLTPK": "Salon"}, overwrite=True)

    def test_parse_room_presets_and_custom(self) -> None:
        self.assertEqual(parse_room_choice("1"), "Salon")
        self.assertEqual(parse_room_choice("2"), "Chambre")
        self.assertEqual(parse_room_choice("Salon"), "Salon")
        self.assertEqual(parse_room_choice("3", " Bureau "), "Bureau")
        self.assertIsNone(parse_room_choice("3", "  "))
        self.assertIsNone(parse_room_choice(""))

    def test_assign_rooms_prompts_once_per_homepod(self) -> None:
        answers = iter(["1", "2"])
        mapping = assign_rooms(
            [
                {"device_id": "AA:BB:CC:00:00:01", "alias": "HomePod-1", "hap_name": "HomePodSensor EXAMPLE1"},
                {"device_id": "AA:BB:CC:00:00:02", "alias": "HomePod-2", "hap_name": "HomePodSensor EXAMPLE2"},
            ],
            prompt_fn=lambda _: next(answers),
        )
        self.assertEqual(
            mapping,
            {
                "AA:BB:CC:00:00:01": "Salon",
                "AA:BB:CC:00:00:02": "Chambre",
            },
        )

    def test_collector_can_load_mapper_output(self) -> None:
        path = Path(tempfile.mkdtemp()) / "rooms.json"
        write_rooms_file(
            str(path),
            {
                "AA:BB:CC:00:00:01": "Salon",
                "AA:BB:CC:00:00:02": "Chambre",
            },
            overwrite=True,
        )
        rooms = load_rooms_map(str(path))
        self.assertEqual(
            resolve_sensor_name("aa:bb:cc:00:00:01", "HomePod-1", "HomePodSensor EXAMPLE1", rooms),
            "Salon",
        )


if __name__ == "__main__":
    unittest.main()
