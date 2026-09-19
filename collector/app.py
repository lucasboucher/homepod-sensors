#!/usr/bin/env python3
"""Collect HomePod temperature and humidity via HAP and POST them to an HTTP endpoint."""

from __future__ import annotations

import json
import logging
import os
import signal
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from typing import Any

from homekit.controller import Controller
from homekit.model.characteristics import CharacteristicsTypes

LOG_FORMAT = "%(levelname)s %(message)s"
DEFAULT_PAIRING_FILE = "/app/pairing.json"
DEFAULT_POLL_INTERVAL_SECONDS = 600
DEFAULT_HOMEKIT_TIMEOUT_SECONDS = 15
DEFAULT_HTTP_TIMEOUT_SECONDS = 10
HOMEKIT_ATTEMPTS = 3
HTTP_ATTEMPTS = 3
HOMEKIT_BACKOFF_SECONDS = (1, 2)
HTTP_BACKOFF_SECONDS = (1, 2)

TEMPERATURE_UUID = CharacteristicsTypes.get_uuid(CharacteristicsTypes.TEMPERATURE_CURRENT).upper()
HUMIDITY_UUID = CharacteristicsTypes.get_uuid(CharacteristicsTypes.RELATIVE_HUMIDITY_CURRENT).upper()

LOGGER = logging.getLogger("homepod-collector")
STOP_EVENT = threading.Event()


def configure_logging() -> None:
    logging.basicConfig(level=logging.INFO, format=LOG_FORMAT, stream=sys.stdout, force=True)
    logging.getLogger("homekit").setLevel(logging.WARNING)
    logging.getLogger("zeroconf").setLevel(logging.ERROR)


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise SystemExit(f"ERROR Invalid integer for {name}") from exc
    if value <= 0:
        raise SystemExit(f"ERROR {name} must be greater than 0")
    return value


def env_str(*names: str) -> str:
    for name in names:
        raw = os.environ.get(name)
        if raw is not None and raw.strip():
            return raw.strip()
    return ""


def env_int_from(*names: str, default: int) -> int:
    raw = env_str(*names)
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise SystemExit(f"ERROR Invalid integer for {names[0]}") from exc
    if value <= 0:
        raise SystemExit(f"ERROR {names[0]} must be greater than 0")
    return value


def load_config() -> dict[str, Any]:
    pairing_file = env_str("PAIRING_FILE") or DEFAULT_PAIRING_FILE
    endpoint_url = env_str("HTTP_ENDPOINT_URL", "WEBHOOK_URL", "N8N_WEBHOOK_URL")
    if not endpoint_url:
        raise SystemExit("ERROR HTTP_ENDPOINT_URL is required")
    if not endpoint_url.startswith(("http://", "https://")):
        raise SystemExit("ERROR HTTP_ENDPOINT_URL must be an HTTP or HTTPS URL")

    return {
        "pairing_file": pairing_file,
        "endpoint_url": endpoint_url,
        "poll_interval_seconds": env_int("POLL_INTERVAL_SECONDS", DEFAULT_POLL_INTERVAL_SECONDS),
        "homekit_timeout_seconds": env_int("HOMEKIT_TIMEOUT_SECONDS", DEFAULT_HOMEKIT_TIMEOUT_SECONDS),
        "http_timeout_seconds": env_int_from(
            "HTTP_TIMEOUT_SECONDS",
            "N8N_TIMEOUT_SECONDS",
            default=DEFAULT_HTTP_TIMEOUT_SECONDS,
        ),
    }


def exception_label(exc: BaseException) -> str:
    return type(exc).__name__


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def next_aligned_unix(now_unix: float, interval_seconds: int) -> int:
    """Return the next exclusive Unix-time multiple of interval_seconds after now."""
    if interval_seconds <= 0:
        raise ValueError("interval_seconds must be greater than 0")
    now_sec = int(now_unix)
    return (now_sec // interval_seconds + 1) * interval_seconds


def next_aligned_datetime(now: datetime, interval_seconds: int) -> datetime:
    """Return the next exclusive clock-aligned slot strictly after `now`.

    Slots are multiples of `interval_seconds` on the Unix epoch (UTC). For 600
    that is HH:00, HH:10, HH:20, HH:30, HH:40, HH:50. A time that already sits
    on a slot yields the following slot. Hour and midnight boundaries wrap
    normally. Missed slots are skipped: the result is always the next future
    slot, never a catch-up burst.
    """
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    next_unix = next_aligned_unix(now.timestamp(), interval_seconds)
    return datetime.fromtimestamp(next_unix, tz=timezone.utc)


def seconds_until_next_aligned_slot(now: datetime, interval_seconds: int) -> float:
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    return max(0.0, next_aligned_unix(now.timestamp(), interval_seconds) - now.timestamp())


def as_json_number(value: Any) -> int | float:
    if isinstance(value, bool) or value is None:
        raise TypeError("non-numeric value")
    if isinstance(value, int):
        return value
    number = float(value)
    if number.is_integer():
        return int(number)
    return number


def normalize_characteristic_uuid(type_value: Any) -> str:
    if not isinstance(type_value, str) or not type_value:
        return ""
    try:
        return CharacteristicsTypes.get_uuid(type_value).upper()
    except (KeyError, ValueError, TypeError):
        return type_value.upper()


def find_sensor_characteristics(accessories: list[dict[str, Any]]) -> tuple[list[tuple[int, int]], list[tuple[int, int]]]:
    temperature_ids: list[tuple[int, int]] = []
    humidity_ids: list[tuple[int, int]] = []

    for accessory in accessories:
        aid = accessory.get("aid")
        if not isinstance(aid, int):
            continue
        for service in accessory.get("services", []):
            for characteristic in service.get("characteristics", []):
                iid = characteristic.get("iid")
                if not isinstance(iid, int):
                    continue
                char_uuid = normalize_characteristic_uuid(characteristic.get("type"))
                if char_uuid == TEMPERATURE_UUID:
                    temperature_ids.append((aid, iid))
                elif char_uuid == HUMIDITY_UUID:
                    humidity_ids.append((aid, iid))

    return temperature_ids, humidity_ids


def first_numeric_value(
    results: dict[tuple[int, int], dict[str, Any]],
    characteristic_ids: list[tuple[int, int]],
) -> int | float | None:
    for char_id in characteristic_ids:
        payload = results.get(char_id) or {}
        if "value" not in payload:
            continue
        try:
            return as_json_number(payload["value"])
        except (TypeError, ValueError):
            continue
    return None


def close_pairing(pairing: Any) -> None:
    close = getattr(pairing, "close", None)
    if callable(close):
        try:
            close()
        except Exception:
            pass


def read_homepod_sensors(name: str, pairing: Any) -> dict[str, Any]:
    accessories = pairing.list_accessories_and_characteristics()
    temperature_ids, humidity_ids = find_sensor_characteristics(accessories)
    requested = temperature_ids + humidity_ids
    if not requested:
        raise RuntimeError("no temperature or humidity characteristics found")

    results = pairing.get_characteristics(requested)
    temperature = first_numeric_value(results, temperature_ids)
    humidity = first_numeric_value(results, humidity_ids)
    if temperature is None and humidity is None:
        raise RuntimeError("temperature and humidity readings were empty")

    reading: dict[str, Any] = {"name": name}
    if temperature is not None:
        reading["temperature_c"] = temperature
    if humidity is not None:
        reading["humidity_percent"] = humidity
    return reading


def collect_homepod(name: str, pairing: Any) -> dict[str, Any] | None:
    last_error = "unknown error"
    for attempt in range(1, HOMEKIT_ATTEMPTS + 1):
        try:
            return read_homepod_sensors(name, pairing)
        except Exception as exc:
            last_error = exception_label(exc)
            close_pairing(pairing)
            if attempt < HOMEKIT_ATTEMPTS:
                delay = HOMEKIT_BACKOFF_SECONDS[min(attempt - 1, len(HOMEKIT_BACKOFF_SECONDS) - 1)]
                LOGGER.warning(
                    "Retrying %s after %s (attempt %s/%s)",
                    name,
                    last_error,
                    attempt,
                    HOMEKIT_ATTEMPTS,
                )
                time.sleep(delay)
    LOGGER.error("Failed to collect from %s: %s", name, last_error)
    return None


def collect_all(pairings: dict[str, Any]) -> list[dict[str, Any]]:
    LOGGER.info("Collecting sensor data")
    names = list(pairings.keys())
    readings: list[dict[str, Any] | None] = [None] * len(names)

    def _collect(index: int, name: str) -> None:
        readings[index] = collect_homepod(name, pairings[name])

    with ThreadPoolExecutor(max_workers=max(1, len(names)), thread_name_prefix="homepod") as executor:
        futures = [executor.submit(_collect, index, name) for index, name in enumerate(names)]
        for future in futures:
            try:
                future.result()
            except Exception as exc:
                LOGGER.error("Unexpected collector error: %s", exception_label(exc))

    successful: list[dict[str, Any]] = []
    for reading in readings:
        if not reading:
            continue
        temperature = reading.get("temperature_c")
        humidity = reading.get("humidity_percent")
        temperature_text = f"{temperature}°C" if temperature is not None else "unavailable"
        humidity_text = f"{humidity}%" if humidity is not None else "unavailable"
        LOGGER.info("%s: temperature=%s humidity=%s", reading["name"], temperature_text, humidity_text)
        successful.append(reading)
    return successful


def post_http_endpoint(endpoint_url: str, payload: dict[str, Any], timeout_seconds: int) -> bool:
    body = json.dumps(payload).encode("utf-8")

    last_error = "unknown error"
    for attempt in range(1, HTTP_ATTEMPTS + 1):
        request = urllib.request.Request(
            endpoint_url,
            data=body,
            headers={
                "Content-Type": "application/json",
                "User-Agent": "homepod-collector/1.0",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
                status = getattr(response, "status", 200)
                if 200 <= status < 300:
                    return True
                last_error = f"HTTP {status}"
        except urllib.error.HTTPError as exc:
            last_error = f"HTTP {exc.code}"
        except Exception as exc:
            last_error = exception_label(exc)

        if attempt < HTTP_ATTEMPTS:
            delay = HTTP_BACKOFF_SECONDS[min(attempt - 1, len(HTTP_BACKOFF_SECONDS) - 1)]
            LOGGER.warning(
                "Retrying HTTP endpoint after %s (attempt %s/%s)",
                last_error,
                attempt,
                HTTP_ATTEMPTS,
            )
            time.sleep(delay)

    LOGGER.error("Failed to send sensor readings: %s", last_error)
    return False


def load_controller(pairing_file: str) -> Controller:
    if not os.path.isfile(pairing_file):
        raise SystemExit(f"ERROR Pairing file not found: {pairing_file}")

    controller = Controller()
    try:
        controller.load_data(pairing_file)
    except Exception as exc:
        raise SystemExit(f"ERROR Could not load pairing file: {exception_label(exc)}") from exc

    pairings = controller.get_pairings()
    if not pairings:
        raise SystemExit("ERROR Pairing file does not contain any HomePods")
    return controller


def request_shutdown(signum: int, _frame: Any) -> None:
    LOGGER.info("Received signal %s, shutting down", signum)
    STOP_EVENT.set()


def run_forever() -> None:
    configure_logging()
    LOGGER.info("Starting HomePod collector")

    config = load_config()
    socket.setdefaulttimeout(config["homekit_timeout_seconds"])
    controller = load_controller(config["pairing_file"])
    pairings = controller.get_pairings()
    LOGGER.info("Loaded %s HomePods", len(pairings))

    signal.signal(signal.SIGTERM, request_shutdown)
    signal.signal(signal.SIGINT, request_shutdown)

    interval = config["poll_interval_seconds"]
    while not STOP_EVENT.is_set():
        now = datetime.now(timezone.utc)
        delay = seconds_until_next_aligned_slot(now, interval)
        next_slot = next_aligned_datetime(now, interval)
        LOGGER.info("Next collection at %s", next_slot.strftime("%Y-%m-%dT%H:%M:%SZ"))
        if STOP_EVENT.wait(delay):
            break

        try:
            sensors = collect_all(pairings)
            if sensors:
                LOGGER.info("Sending %s sensor readings", len(sensors))
                payload = {
                    "timestamp": utc_timestamp(),
                    "sensors": sensors,
                }
                post_http_endpoint(
                    config["endpoint_url"],
                    payload,
                    config["http_timeout_seconds"],
                )
            else:
                LOGGER.error("No sensor readings collected in this cycle")
            LOGGER.info("Collection completed")
        except Exception as exc:
            LOGGER.error("Collection cycle failed: %s", exception_label(exc))


if __name__ == "__main__":
    run_forever()
