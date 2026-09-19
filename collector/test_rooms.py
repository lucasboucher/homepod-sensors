#!/usr/bin/env python3
"""Room-name resolution tests. No real HomePods, IDs, or secrets required."""

from __future__ import annotations

import json
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

from app import (  # noqa: E402
    ACCESSORY_INFORMATION_UUID,
    NAME_UUID,
    hap_accessory_name,
    load_rooms_map,
    resolve_sensor_name,
)

EXAMPLE_ID_1 = "00:00:00:00:00:01"
EXAMPLE_ID_2 = "00:00:00:00:00:02"


def _write_rooms(payload: object) -> str:
    handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
    json.dump(payload, handle)
    handle.close()
    return handle.name


class RoomMappingTests(unittest.TestCase):
    def test_rooms_file_match_uses_room_name(self) -> None:
        rooms = {EXAMPLE_ID_1.casefold(): "Living-Room"}
        self.assertEqual(
            resolve_sensor_name(EXAMPLE_ID_1, "HomePodSensor EXAMPLE1", "HomePodSensor EXAMPLE1", rooms),
            "Living-Room",
        )

    def test_missing_entry_falls_back_to_hap_then_alias(self) -> None:
        rooms = {EXAMPLE_ID_1.casefold(): "Living-Room"}
        self.assertEqual(
            resolve_sensor_name(EXAMPLE_ID_2, "HomePod-2", "HomePodSensor EXAMPLE2", rooms),
            "HomePodSensor EXAMPLE2",
        )
        self.assertEqual(
            resolve_sensor_name(EXAMPLE_ID_2, "HomePod-2", None, rooms),
            "HomePod-2",
        )
        self.assertEqual(
            resolve_sensor_name(EXAMPLE_ID_2, "HomePod-2", "   ", rooms),
            "HomePod-2",
        )

    def test_missing_rooms_file_does_not_fail(self) -> None:
        self.assertEqual(load_rooms_map(str(Path(tempfile.mkdtemp()) / "missing-rooms.json")), {})
        self.assertEqual(
            resolve_sensor_name(EXAMPLE_ID_1, "HomePod-1", "HomePodSensor EXAMPLE1", {}),
            "HomePodSensor EXAMPLE1",
        )

    def test_empty_and_invalid_values_are_ignored(self) -> None:
        path = _write_rooms(
            {
                EXAMPLE_ID_1: "Living-Room",
                EXAMPLE_ID_2: "   ",
                "": "Ignored",
                "00:00:00:00:00:03": "",
                "00:00:00:00:00:04": 12,
            }
        )
        rooms = load_rooms_map(path)
        self.assertEqual(rooms, {EXAMPLE_ID_1.casefold(): "Living-Room"})
        self.assertEqual(
            resolve_sensor_name(EXAMPLE_ID_2, "HomePod-2", "HomePodSensor EXAMPLE2", rooms),
            "HomePodSensor EXAMPLE2",
        )

    def test_invalid_json_and_non_object_are_ignored(self) -> None:
        bad_json = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
        bad_json.write("{not json")
        bad_json.close()
        self.assertEqual(load_rooms_map(bad_json.name), {})
        array_path = _write_rooms(["Living-Room"])
        self.assertEqual(load_rooms_map(array_path), {})

    def test_multiple_homepods_resolve_independently(self) -> None:
        rooms = {
            EXAMPLE_ID_1.casefold(): "Living-Room",
            EXAMPLE_ID_2.casefold(): "Bedroom",
        }
        self.assertEqual(
            resolve_sensor_name(EXAMPLE_ID_1.lower(), "alias-1", "hap-1", rooms),
            "Living-Room",
        )
        self.assertEqual(
            resolve_sensor_name(EXAMPLE_ID_2, "alias-2", "hap-2", rooms),
            "Bedroom",
        )

    def test_pairing_alias_can_map_if_present(self) -> None:
        rooms = {"homepod-1": "Living-Room"}
        self.assertEqual(
            resolve_sensor_name(EXAMPLE_ID_1, "HomePod-1", "HomePodSensor EXAMPLE1", rooms),
            "Living-Room",
        )

    def test_hap_name_is_read_from_accessory_information(self) -> None:
        accessories = [
            {
                "aid": 1,
                "services": [
                    {
                        "type": ACCESSORY_INFORMATION_UUID,
                        "characteristics": [
                            {"iid": 2, "type": NAME_UUID, "value": "HomePodSensor EXAMPLE1"},
                        ],
                    }
                ],
            }
        ]
        self.assertEqual(hap_accessory_name(accessories, {1}), "HomePodSensor EXAMPLE1")
        self.assertIsNone(hap_accessory_name([{"aid": 1, "services": []}], {1}))

    def test_example_rooms_file_is_fictitious(self) -> None:
        payload = json.loads((COLLECTOR_DIR / "rooms.example.json").read_text(encoding="utf-8"))
        self.assertEqual(
            payload,
            {
                "00:00:00:00:00:01": "Living-Room",
                "00:00:00:00:00:02": "Bedroom",
            },
        )


if __name__ == "__main__":
    unittest.main()
