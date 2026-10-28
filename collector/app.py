#!/usr/bin/env python3
"""Collect HomePod temperature and humidity via HAP and POST them to an HTTP endpoint."""

from __future__ import annotations

import json
import logging
import multiprocessing
import os
import signal
import socket
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import warnings
from datetime import datetime, timezone
from queue import Empty as QueueEmpty
from typing import Any

from homekit.controller import Controller
from homekit.model.characteristics import CharacteristicsTypes

LOG_FORMAT = "%(levelname)s %(message)s"
DEFAULT_PAIRING_FILE = "/app/pairing.json"
DEFAULT_ROOMS_FILE = "/app/rooms.json"
DEFAULT_POLL_INTERVAL_SECONDS = 600
DEFAULT_HOMEKIT_TIMEOUT_SECONDS = 15
DEFAULT_HTTP_TIMEOUT_SECONDS = 10
DEFAULT_HOMEKIT_ATTEMPT_DEADLINE_SECONDS = 45
DEFAULT_HEARTBEAT_FILE = "/tmp/homepod-collector-heartbeat"
DEFAULT_HEARTBEAT_MAX_AGE_SECONDS = 1800
HOMEKIT_ATTEMPTS = 3
HTTP_ATTEMPTS = 3
HOMEKIT_BACKOFF_SECONDS = (1, 2)
HTTP_BACKOFF_SECONDS = (1, 2)
PROCESS_TERMINATE_GRACE_SECONDS = 5
PROCESS_KILL_GRACE_SECONDS = 2

TEMPERATURE_UUID = CharacteristicsTypes.get_uuid(CharacteristicsTypes.TEMPERATURE_CURRENT).upper()
HUMIDITY_UUID = CharacteristicsTypes.get_uuid(CharacteristicsTypes.RELATIVE_HUMIDITY_CURRENT).upper()
NAME_UUID = CharacteristicsTypes.get_uuid(CharacteristicsTypes.NAME).upper()
ACCESSORY_INFORMATION_UUID = "0000003E-0000-1000-8000-0026BB765291"

LOGGER = logging.getLogger("homepod-collector")
STOP_EVENT = threading.Event()
_HOMEKIT_PATCHED = False


def configure_logging() -> None:
    logging.basicConfig(level=logging.INFO, format=LOG_FORMAT, stream=sys.stdout, force=True)
    logging.getLogger("homekit").setLevel(logging.WARNING)
    logging.getLogger("zeroconf").setLevel(logging.ERROR)
    warnings.filterwarnings(
        "ignore",
        category=FutureWarning,
        module=r"homekit\.zeroconf_impl(\.|$)",
    )


def patch_homekit_runtime() -> None:
    """Work around homekit 0.19.0 issues with newer zeroconf / failed mDNS lookups.

    - CollectingListener lacks update_service (required by modern zeroconf).
    - IpSession indexes find_device_ip_and_port(None) before checking for None.
    """
    global _HOMEKIT_PATCHED
    if _HOMEKIT_PATCHED:
        return

    try:
        from homekit.exceptions import AccessoryNotFoundError
        from homekit.zeroconf_impl import CollectingListener
        import homekit.controller.ip_implementation as ip_implementation
        import homekit.zeroconf_impl as zeroconf_impl
    except Exception as exc:
        LOGGER.warning("Could not patch homekit runtime: %s", exception_label(exc))
        return

    if not hasattr(CollectingListener, "update_service"):
        CollectingListener.update_service = lambda self, zeroconf, service_type, name: None

    original_find = zeroconf_impl.find_device_ip_and_port

    def find_device_ip_and_port(device_id: str, max_seconds: int = 10):
        result = original_find(device_id, max_seconds)
        if result is None:
            raise AccessoryNotFoundError(f"Device {device_id} not found via mDNS")
        return result

    zeroconf_impl.find_device_ip_and_port = find_device_ip_and_port
    ip_implementation.find_device_ip_and_port = find_device_ip_and_port
    _HOMEKIT_PATCHED = True


def clarify_homekit_exception(exc: BaseException) -> BaseException:
    message = str(exc)
    if isinstance(exc, TypeError) and "NoneType" in message and "subscriptable" in message:
        return RuntimeError("HomePod not found via HAP/mDNS (stale IP and discovery failed)")
    if isinstance(exc, AttributeError) and "sec_http" in message:
        return RuntimeError("HomeKit connection failed (incomplete session)")
    return exc


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
        "rooms_file": env_str("ROOMS_FILE") or DEFAULT_ROOMS_FILE,
        "endpoint_url": endpoint_url,
        "poll_interval_seconds": env_int("POLL_INTERVAL_SECONDS", DEFAULT_POLL_INTERVAL_SECONDS),
        "homekit_timeout_seconds": env_int("HOMEKIT_TIMEOUT_SECONDS", DEFAULT_HOMEKIT_TIMEOUT_SECONDS),
        "homekit_attempt_deadline_seconds": env_int(
            "HOMEKIT_ATTEMPT_DEADLINE_SECONDS",
            DEFAULT_HOMEKIT_ATTEMPT_DEADLINE_SECONDS,
        ),
        "http_timeout_seconds": env_int_from(
            "HTTP_TIMEOUT_SECONDS",
            "N8N_TIMEOUT_SECONDS",
            default=DEFAULT_HTTP_TIMEOUT_SECONDS,
        ),
        "heartbeat_file": env_str("HEARTBEAT_FILE") or DEFAULT_HEARTBEAT_FILE,
    }


def touch_heartbeat(path: str) -> None:
    """Record that the collector main loop is still making progress."""
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(utc_timestamp() + "\n")


def heartbeat_is_fresh(path: str, max_age_seconds: int, now: float | None = None) -> bool:
    if max_age_seconds <= 0:
        return False
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return False
    current = time.time() if now is None else now
    return (current - mtime) <= max_age_seconds


def run_healthcheck() -> int:
    """Exit 0 when heartbeat is fresh; used by Docker HEALTHCHECK."""
    path = env_str("HEARTBEAT_FILE") or DEFAULT_HEARTBEAT_FILE
    max_age = env_int("HEARTBEAT_MAX_AGE_SECONDS", DEFAULT_HEARTBEAT_MAX_AGE_SECONDS)
    return 0 if heartbeat_is_fresh(path, max_age) else 1


def apply_pairing_endpoint(pairing: Any, ip: Any, port: Any) -> None:
    data = getattr(pairing, "pairing_data", None)
    if not isinstance(data, dict):
        return
    if ip not in (None, ""):
        data["AccessoryIP"] = ip
    if port is not None:
        data["AccessoryPort"] = port


def exception_label(exc: BaseException) -> str:
    name = type(exc).__name__
    message = str(exc).strip()
    if message:
        return f"{name}: {message}"
    return name


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


def normalize_rooms_key(value: str) -> str:
    return value.strip().casefold()


def pairing_accessory_id(pairing: Any) -> str:
    data = getattr(pairing, "pairing_data", None)
    if not isinstance(data, dict):
        getter = getattr(pairing, "_get_pairing_data", None)
        data = getter() if callable(getter) else None
    if not isinstance(data, dict):
        return ""
    raw = data.get("AccessoryPairingID")
    if not isinstance(raw, str):
        return ""
    return raw.strip()


def load_rooms_map(path: str) -> dict[str, str]:
    if not path or not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception as exc:
        LOGGER.warning("Ignoring rooms file %s: %s", path, exception_label(exc))
        return {}
    if not isinstance(payload, dict):
        LOGGER.warning("Ignoring rooms file %s: root value must be an object", path)
        return {}

    rooms: dict[str, str] = {}
    for raw_key, raw_value in payload.items():
        if not isinstance(raw_key, str) or not isinstance(raw_value, str):
            continue
        key = normalize_rooms_key(raw_key)
        value = raw_value.strip()
        if not key or not value:
            continue
        rooms[key] = value
    return rooms


def hap_accessory_name(accessories: list[dict[str, Any]], preferred_aids: set[int] | None = None) -> str | None:
    preferred = preferred_aids or set()

    def _name_from_accessory(accessory: dict[str, Any]) -> str | None:
        for service in accessory.get("services", []):
            service_type = str(service.get("type") or "").upper()
            if service_type not in (ACCESSORY_INFORMATION_UUID, "3E"):
                continue
            for characteristic in service.get("characteristics", []):
                if normalize_characteristic_uuid(characteristic.get("type")) != NAME_UUID:
                    continue
                value = characteristic.get("value")
                if isinstance(value, str) and value.strip():
                    return value.strip()
        return None

    for accessory in accessories:
        aid = accessory.get("aid")
        if preferred and aid not in preferred:
            continue
        name = _name_from_accessory(accessory)
        if name:
            return name
    if preferred:
        for accessory in accessories:
            name = _name_from_accessory(accessory)
            if name:
                return name
    return None


def resolve_sensor_name(
    device_id: str,
    pairing_alias: str,
    hap_name: str | None,
    rooms: dict[str, str],
) -> str:
    for candidate in (device_id, pairing_alias):
        if not candidate:
            continue
        mapped = rooms.get(normalize_rooms_key(candidate))
        if mapped:
            return mapped
    if isinstance(hap_name, str) and hap_name.strip():
        return hap_name.strip()
    return pairing_alias


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
    """Close the HAP session and drop it so the next call opens a fresh one.

    homekit IpPairing.close() shuts the socket but leaves pairing.session set.
    Reusing that dead session yields immediate AttributeError on later reads.
    """
    close = getattr(pairing, "close", None)
    if callable(close):
        try:
            close()
        except Exception:
            pass
    if hasattr(pairing, "session"):
        try:
            pairing.session = None
        except Exception:
            pass


def read_homepod_snapshot(pairing: Any) -> dict[str, Any]:
    try:
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
    except Exception as exc:
        clarified = clarify_homekit_exception(exc)
        if clarified is exc:
            raise
        raise clarified from exc

    preferred_aids = {aid for aid, _iid in requested}
    return {
        "device_id": pairing_accessory_id(pairing),
        "hap_name": hap_accessory_name(accessories, preferred_aids),
        "temperature_c": temperature,
        "humidity_percent": humidity,
    }


def read_homepod_sensors(name: str, pairing: Any, rooms: dict[str, str]) -> dict[str, Any]:
    snapshot = read_homepod_snapshot(pairing)
    display_name = resolve_sensor_name(
        snapshot["device_id"],
        name,
        snapshot["hap_name"],
        rooms,
    )
    reading: dict[str, Any] = {"name": display_name}
    if snapshot["temperature_c"] is not None:
        reading["temperature_c"] = snapshot["temperature_c"]
    if snapshot["humidity_percent"] is not None:
        reading["humidity_percent"] = snapshot["humidity_percent"]
    return reading


def _homepod_attempt_worker(
    pairing_file: str,
    name: str,
    rooms: dict[str, str],
    homekit_timeout_seconds: int,
    result_queue: Any,
) -> None:
    """Child process: one HomeKit read. Pairing objects are not picklable."""
    try:
        configure_logging()
        patch_homekit_runtime()
        socket.setdefaulttimeout(homekit_timeout_seconds)
        controller = load_controller(pairing_file)
        pairings = controller.get_pairings()
        pairing = pairings.get(name)
        if pairing is None:
            result_queue.put({"ok": False, "error": f"pairing alias not found: {name}"})
            return
        try:
            reading = read_homepod_sensors(name, pairing, rooms)
            ip, port = pairing_endpoint(pairing)
            result_queue.put(
                {
                    "ok": True,
                    "reading": reading,
                    "endpoint": [ip, port],
                }
            )
        finally:
            close_pairing(pairing)
    except SystemExit as exc:
        result_queue.put({"ok": False, "error": str(exc) or "SystemExit"})
    except BaseException as exc:
        result_queue.put({"ok": False, "error": exception_label(exc)})


def _stop_process(proc: Any) -> None:
    if not proc.is_alive():
        return
    proc.terminate()
    proc.join(PROCESS_TERMINATE_GRACE_SECONDS)
    if proc.is_alive():
        proc.kill()
        proc.join(PROCESS_KILL_GRACE_SECONDS)


def run_homepod_attempt_with_deadline(
    pairing_file: str,
    name: str,
    rooms: dict[str, str],
    homekit_timeout_seconds: int,
    deadline_seconds: int,
    *,
    process_factory: Any | None = None,
    queue_factory: Any | None = None,
) -> dict[str, Any]:
    """Run one HomeKit attempt in a spawn child; kill it if it exceeds deadline.

    Returns a worker payload dict with ok=True/False. Raises TimeoutError when
    the child is still alive after the deadline (busy-loop / hung HAP).
    """
    ctx = multiprocessing.get_context("spawn")
    make_queue = queue_factory or ctx.Queue
    result_queue = make_queue(1)
    factory = process_factory or ctx.Process
    proc = factory(
        target=_homepod_attempt_worker,
        args=(pairing_file, name, rooms, homekit_timeout_seconds, result_queue),
        daemon=True,
    )
    proc.start()
    proc.join(deadline_seconds)
    if proc.is_alive():
        _stop_process(proc)
        raise TimeoutError(f"HomeKit attempt exceeded {deadline_seconds}s deadline")

    try:
        return result_queue.get_nowait()
    except QueueEmpty as exc:
        raise RuntimeError(
            f"HomeKit worker exited without result (exitcode={proc.exitcode})"
        ) from exc


def collect_homepod(
    name: str,
    pairing: Any,
    rooms: dict[str, str],
    *,
    pairing_file: str,
    homekit_timeout_seconds: int = DEFAULT_HOMEKIT_TIMEOUT_SECONDS,
    attempt_deadline_seconds: int = DEFAULT_HOMEKIT_ATTEMPT_DEADLINE_SECONDS,
) -> dict[str, Any] | None:
    last_error = "unknown error"
    for attempt in range(1, HOMEKIT_ATTEMPTS + 1):
        try:
            payload = run_homepod_attempt_with_deadline(
                pairing_file,
                name,
                rooms,
                homekit_timeout_seconds,
                attempt_deadline_seconds,
            )
            if not payload.get("ok"):
                raise RuntimeError(str(payload.get("error") or "unknown worker error"))
            endpoint = payload.get("endpoint") or [None, None]
            if isinstance(endpoint, (list, tuple)) and len(endpoint) >= 2:
                apply_pairing_endpoint(pairing, endpoint[0], endpoint[1])
            close_pairing(pairing)
            reading = payload.get("reading")
            if not isinstance(reading, dict):
                raise RuntimeError("worker returned no reading")
            return reading
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


def _write_json_file(path: str, payload: dict[str, Any]) -> None:
    """Write JSON via a temp file in the system temp dir, then replace.

    Staging in /tmp avoids PermissionError when the pairing file lives in a
    root-owned directory like /app. os.replace often fails across bind-mount
    filesystems (EXDEV); fall back to an in-place write in that case.
    """
    text = json.dumps(payload, indent=2) + "\n"
    fd, tmp_path = tempfile.mkstemp(prefix="homepod-pairing-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        try:
            os.replace(tmp_path, path)
            tmp_path = ""
        except OSError:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


def pairing_endpoint(pairing: Any) -> tuple[Any, Any]:
    data = getattr(pairing, "pairing_data", None)
    if not isinstance(data, dict):
        getter = getattr(pairing, "_get_pairing_data", None)
        data = getter() if callable(getter) else None
    if not isinstance(data, dict):
        return (None, None)
    return (data.get("AccessoryIP"), data.get("AccessoryPort"))


def pairing_endpoints(pairings: dict[str, Any]) -> dict[str, tuple[Any, Any]]:
    return {alias: pairing_endpoint(pairing) for alias, pairing in pairings.items()}


def persist_pairing_endpoints(
    pairing_file: str,
    pairings: dict[str, Any],
    before: dict[str, tuple[Any, Any]],
) -> dict[str, tuple[Any, Any]]:
    """Persist AccessoryIP/AccessoryPort when homekit discovers newer endpoints.

    Only those two fields are rewritten so secrets and file shape stay intact.
    Best-effort: logs a warning if the pairing file is not writable.
    """
    after = pairing_endpoints(pairings)
    changed = {
        alias: endpoint
        for alias, endpoint in after.items()
        if endpoint != before.get(alias) and endpoint[0] not in (None, "")
    }
    if not changed:
        return after

    try:
        with open(pairing_file, encoding="utf-8") as handle:
            payload = json.load(handle)
        if not isinstance(payload, dict):
            raise ValueError("pairing file root must be an object")

        updated_aliases: list[str] = []
        for alias, (ip, port) in changed.items():
            entry = payload.get(alias)
            if not isinstance(entry, dict):
                continue
            if ip is not None:
                entry["AccessoryIP"] = ip
            if port is not None:
                entry["AccessoryPort"] = port
            updated_aliases.append(alias)

        if not updated_aliases:
            return after

        _write_json_file(pairing_file, payload)
        LOGGER.info("Persisted updated HomePod endpoints for %s", ", ".join(updated_aliases))
    except Exception as exc:
        LOGGER.warning(
            "Could not persist HomePod endpoints to %s: %s",
            pairing_file,
            exception_label(exc),
        )
    return after


def collect_all(
    pairings: dict[str, Any],
    rooms: dict[str, str],
    *,
    pairing_file: str,
    homekit_timeout_seconds: int = DEFAULT_HOMEKIT_TIMEOUT_SECONDS,
    attempt_deadline_seconds: int = DEFAULT_HOMEKIT_ATTEMPT_DEADLINE_SECONDS,
) -> list[dict[str, Any]]:
    """Collect HomePods one at a time to avoid concurrent mDNS browsers."""
    LOGGER.info("Collecting sensor data")
    successful: list[dict[str, Any]] = []

    for name, pairing in pairings.items():
        try:
            reading = collect_homepod(
                name,
                pairing,
                rooms,
                pairing_file=pairing_file,
                homekit_timeout_seconds=homekit_timeout_seconds,
                attempt_deadline_seconds=attempt_deadline_seconds,
            )
        except Exception as exc:
            LOGGER.error("Unexpected collector error for %s: %s", name, exception_label(exc))
            continue
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
    patch_homekit_runtime()
    LOGGER.info("Starting HomePod collector")

    config = load_config()
    socket.setdefaulttimeout(config["homekit_timeout_seconds"])
    controller = load_controller(config["pairing_file"])
    pairings = controller.get_pairings()
    LOGGER.info("Loaded %s HomePods", len(pairings))
    rooms = load_rooms_map(config["rooms_file"])
    if rooms:
        LOGGER.info("Loaded %s room mapping(s)", len(rooms))
    else:
        LOGGER.info("No room mappings; using HAP or pairing aliases")

    signal.signal(signal.SIGTERM, request_shutdown)
    signal.signal(signal.SIGINT, request_shutdown)

    touch_heartbeat(config["heartbeat_file"])
    endpoint_snapshot = pairing_endpoints(pairings)
    interval = config["poll_interval_seconds"]
    while not STOP_EVENT.is_set():
        now = datetime.now(timezone.utc)
        delay = seconds_until_next_aligned_slot(now, interval)
        next_slot = next_aligned_datetime(now, interval)
        LOGGER.info("Next collection at %s", next_slot.strftime("%Y-%m-%dT%H:%M:%SZ"))
        if STOP_EVENT.wait(delay):
            break

        try:
            sensors = collect_all(
                pairings,
                rooms,
                pairing_file=config["pairing_file"],
                homekit_timeout_seconds=config["homekit_timeout_seconds"],
                attempt_deadline_seconds=config["homekit_attempt_deadline_seconds"],
            )
            endpoint_snapshot = persist_pairing_endpoints(
                config["pairing_file"],
                pairings,
                endpoint_snapshot,
            )
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
        finally:
            try:
                touch_heartbeat(config["heartbeat_file"])
            except Exception as exc:
                LOGGER.warning("Could not update heartbeat: %s", exception_label(exc))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--healthcheck":
        raise SystemExit(run_healthcheck())
    run_forever()
