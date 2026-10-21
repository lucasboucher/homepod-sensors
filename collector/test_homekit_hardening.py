#!/usr/bin/env python3
"""Tests for HomeKit runtime hardening helpers."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


def _install_homekit_stub() -> None:
    if "homekit.controller" in sys.modules:
        return

    homekit = types.ModuleType("homekit")
    controller = types.ModuleType("homekit.controller")
    model = types.ModuleType("homekit.model")
    characteristics = types.ModuleType("homekit.model.characteristics")

    class _CharacteristicsTypes:
        TEMPERATURE_CURRENT = "temperature"
        RELATIVE_HUMIDITY_CURRENT = "humidity"
        NAME = "name"

        @staticmethod
        def get_uuid(value: str) -> str:
            return value

    characteristics.CharacteristicsTypes = _CharacteristicsTypes
    controller.Controller = object
    homekit.controller = controller
    homekit.model = model
    model.characteristics = characteristics

    sys.modules["homekit"] = homekit
    sys.modules["homekit.controller"] = controller
    sys.modules["homekit.model"] = model
    sys.modules["homekit.model.characteristics"] = characteristics


_install_homekit_stub()

import app  # noqa: E402


class ClosePairingTests(unittest.TestCase):
    def test_close_pairing_clears_session(self) -> None:
        pairing = types.SimpleNamespace(session=object(), closed=False)

        def _close() -> None:
            pairing.closed = True

        pairing.close = _close
        app.close_pairing(pairing)
        self.assertTrue(pairing.closed)
        self.assertIsNone(pairing.session)


class ClarifyExceptionTests(unittest.TestCase):
    def test_none_subscriptable_becomes_runtime_error(self) -> None:
        clarified = app.clarify_homekit_exception(TypeError("'NoneType' object is not subscriptable"))
        self.assertIsInstance(clarified, RuntimeError)
        self.assertIn("not found", str(clarified))

    def test_sec_http_attribute_error_becomes_runtime_error(self) -> None:
        clarified = app.clarify_homekit_exception(
            AttributeError("'IpSession' object has no attribute 'sec_http'")
        )
        self.assertIsInstance(clarified, RuntimeError)
        self.assertIn("incomplete session", str(clarified))

    def test_other_errors_pass_through(self) -> None:
        original = ValueError("boom")
        self.assertIs(app.clarify_homekit_exception(original), original)


class PersistEndpointsTests(unittest.TestCase):
    def test_persist_updates_only_ip_and_port(self) -> None:
        payload = {
            "HomePod-1": {
                "AccessoryPairingID": "AA:BB",
                "AccessoryLTPK": "secret",
                "AccessoryIP": "192.168.1.10",
                "AccessoryPort": 12345,
                "Connection": "IP",
            }
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "pairing.json"
            path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

            pairing = types.SimpleNamespace(
                pairing_data={
                    "AccessoryPairingID": "AA:BB",
                    "AccessoryLTPK": "secret",
                    "AccessoryIP": "192.168.1.99",
                    "AccessoryPort": 54321,
                    "Connection": "IP",
                }
            )
            before = {"HomePod-1": ("192.168.1.10", 12345)}
            after = app.persist_pairing_endpoints(str(path), {"HomePod-1": pairing}, before)
            self.assertEqual(after["HomePod-1"], ("192.168.1.99", 54321))

            saved = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(saved["HomePod-1"]["AccessoryIP"], "192.168.1.99")
            self.assertEqual(saved["HomePod-1"]["AccessoryPort"], 54321)
            self.assertEqual(saved["HomePod-1"]["AccessoryLTPK"], "secret")

    def test_write_json_file_when_target_dir_is_not_writable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target_dir = Path(tmp) / "ro"
            target_dir.mkdir()
            path = target_dir / "pairing.json"
            path.write_text("{}\n", encoding="utf-8")
            os.chmod(target_dir, 0o555)
            try:
                app._write_json_file(str(path), {"ok": True})
                self.assertEqual(json.loads(path.read_text(encoding="utf-8")), {"ok": True})
            finally:
                os.chmod(target_dir, 0o755)

    def test_persist_noop_when_unchanged(self) -> None:
        payload = {
            "HomePod-1": {
                "AccessoryIP": "192.168.1.10",
                "AccessoryPort": 12345,
            }
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "pairing.json"
            original = json.dumps(payload, indent=2) + "\n"
            path.write_text(original, encoding="utf-8")
            mtime_before = path.stat().st_mtime_ns

            pairing = types.SimpleNamespace(
                pairing_data={"AccessoryIP": "192.168.1.10", "AccessoryPort": 12345}
            )
            before = {"HomePod-1": ("192.168.1.10", 12345)}
            app.persist_pairing_endpoints(str(path), {"HomePod-1": pairing}, before)
            self.assertEqual(path.read_text(encoding="utf-8"), original)
            self.assertEqual(path.stat().st_mtime_ns, mtime_before)


class PatchHomekitTests(unittest.TestCase):
    def test_patch_adds_update_service_and_raises_on_missing_device(self) -> None:
        class CollectingListener:
            def remove_service(self, *args):
                pass

            def add_service(self, *args):
                pass

        class AccessoryNotFoundError(Exception):
            pass

        zeroconf_impl = types.ModuleType("homekit.zeroconf_impl")
        zeroconf_impl.CollectingListener = CollectingListener
        zeroconf_impl.find_device_ip_and_port = lambda device_id, max_seconds=10: None

        ip_implementation = types.ModuleType("homekit.controller.ip_implementation")
        ip_implementation.find_device_ip_and_port = zeroconf_impl.find_device_ip_and_port

        exceptions = types.ModuleType("homekit.exceptions")
        exceptions.AccessoryNotFoundError = AccessoryNotFoundError

        app._HOMEKIT_PATCHED = False
        with mock.patch.dict(
            sys.modules,
            {
                "homekit.zeroconf_impl": zeroconf_impl,
                "homekit.controller.ip_implementation": ip_implementation,
                "homekit.exceptions": exceptions,
            },
        ):
            app.patch_homekit_runtime()
            self.assertTrue(hasattr(CollectingListener, "update_service"))
            CollectingListener().update_service(None, "_hap._tcp.local.", "x")
            with self.assertRaises(AccessoryNotFoundError):
                zeroconf_impl.find_device_ip_and_port("AA:BB")
            self.assertIs(
                ip_implementation.find_device_ip_and_port,
                zeroconf_impl.find_device_ip_and_port,
            )
        app._HOMEKIT_PATCHED = False


if __name__ == "__main__":
    unittest.main()
