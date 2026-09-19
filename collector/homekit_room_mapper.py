#!/usr/bin/env python3
"""Interactive helper to build a local rooms.json from an existing pairing file.

HomePod stereo pairs are an AirPlay / Home grouping. homekit==0.19.0 / HAP does
not expose a reliable pair membership field, so this tool maps one HomePod at a
time and never guesses pairs.

Run from collector/:

    python3 -m homekit_room_mapper -f /path/to/pairing.json
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
from pathlib import Path
from typing import Any, Callable, Iterable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from app import (  # noqa: E402
    DEFAULT_HOMEKIT_TIMEOUT_SECONDS,
    HOMEKIT_ATTEMPTS,
    HOMEKIT_BACKOFF_SECONDS,
    close_pairing,
    exception_label,
    load_controller,
    pairing_accessory_id,
    read_homepod_snapshot,
)

ROOM_PRESETS = {
    "1": "Salon",
    "2": "Chambre",
}
DEFAULT_OUTPUT = str(Path.home() / "homepod-rooms.json")
PAIRING_SECRET_FIELDS = frozenset(
    {
        "AccessoryLTPK",
        "iOSDeviceLTSK",
        "iOSDeviceLTPK",
        "iOSPairingId",
    }
)


def build_rooms_mapping(assignments: Iterable[tuple[str, str]]) -> dict[str, str]:
    mapping: dict[str, str] = {}
    for device_id, room in assignments:
        if not isinstance(device_id, str) or not isinstance(room, str):
            continue
        key = device_id.strip()
        value = room.strip()
        if not key or not value:
            continue
        mapping[key] = value
    return mapping


def rooms_mapping_contains_secrets(mapping: dict[str, str]) -> bool:
    for key, value in mapping.items():
        combined = f"{key} {value}".upper()
        if key in PAIRING_SECRET_FIELDS or value in PAIRING_SECRET_FIELDS:
            return True
        if "LTPK" in combined or "LTSK" in combined:
            return True
    return False


def write_rooms_file(path: str, mapping: dict[str, str], *, overwrite: bool = False) -> None:
    if rooms_mapping_contains_secrets(mapping):
        raise ValueError("rooms mapping must not contain pairing secrets")
    destination = Path(path).expanduser()
    if destination.exists() and not overwrite:
        raise FileExistsError(f"Refusing to overwrite existing file: {destination}")
    payload = json.dumps(mapping, indent=2, ensure_ascii=False) + "\n"
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    fd = os.open(destination, flags, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
            fd = -1
    finally:
        if fd >= 0:
            os.close(fd)
    os.chmod(destination, 0o600)


def confirm_overwrite(path: str, prompt_fn: Callable[[str], str] = input) -> bool:
    answer = prompt_fn(f"{path} existe déjà. Écraser ? [y/N] ").strip().casefold()
    return answer in {"y", "yes", "o", "oui"}


def parse_room_choice(choice: str, custom_room: str | None = None) -> str | None:
    raw = choice.strip()
    if raw in ROOM_PRESETS:
        return ROOM_PRESETS[raw]
    preset_names = {name.casefold(): name for name in ROOM_PRESETS.values()}
    if raw.casefold() in preset_names:
        return preset_names[raw.casefold()]
    if raw in {"3", "autre", "other"}:
        if custom_room is None:
            return None
        custom = custom_room.strip()
        return custom or None
    if raw:
        return raw
    return None


def format_reading(snapshot: dict[str, Any] | None) -> str:
    if not snapshot:
        return "température=indisponible  humidité=indisponible"
    temperature = snapshot.get("temperature_c")
    humidity = snapshot.get("humidity_percent")
    temperature_text = f"{temperature}°C" if temperature is not None else "indisponible"
    humidity_text = f"{humidity}%" if humidity is not None else "indisponible"
    return f"température={temperature_text}  humidité={humidity_text}"


def collect_snapshot(alias: str, pairing: Any) -> dict[str, Any]:
    last_error = "unknown error"
    for attempt in range(1, HOMEKIT_ATTEMPTS + 1):
        try:
            snapshot = read_homepod_snapshot(pairing)
            snapshot["alias"] = alias
            return snapshot
        except Exception as exc:
            last_error = exception_label(exc)
            close_pairing(pairing)
            if attempt < HOMEKIT_ATTEMPTS:
                delay = HOMEKIT_BACKOFF_SECONDS[min(attempt - 1, len(HOMEKIT_BACKOFF_SECONDS) - 1)]
                print(f"Nouvelle tentative pour {alias} après {last_error} ({attempt}/{HOMEKIT_ATTEMPTS})")
                time.sleep(delay)
    print(f"Lecture impossible pour {alias}: {last_error}")
    return {
        "device_id": pairing_accessory_id(pairing),
        "alias": alias,
        "hap_name": None,
        "temperature_c": None,
        "humidity_percent": None,
    }


def prompt_room_for_homepod(
    index: int,
    total: int,
    snapshot: dict[str, Any],
    prompt_fn: Callable[[str], str] = input,
) -> str:
    alias = snapshot.get("alias") or "HomePod"
    hap_name = snapshot.get("hap_name")
    print()
    print(f"HomePod {index}/{total}  alias={alias}")
    if hap_name and hap_name != alias:
        print(f"  nom HAP={hap_name}")
    print(f"  {format_reading(snapshot)}")
    while True:
        choice = prompt_fn("Pièce [1=Salon, 2=Chambre, 3=autre] : ")
        if choice.strip() in {"3", "autre", "other"}:
            custom = prompt_fn("Nom de la pièce : ")
            room = parse_room_choice("3", custom)
        else:
            room = parse_room_choice(choice)
        if room:
            return room
        print("Choix invalide.")


def assign_rooms(
    snapshots: list[dict[str, Any]],
    prompt_fn: Callable[[str], str] = input,
) -> dict[str, str]:
    assignments: list[tuple[str, str]] = []
    total = len(snapshots)
    for index, snapshot in enumerate(snapshots, start=1):
        device_id = str(snapshot.get("device_id") or "").strip()
        if not device_id:
            print(f"HomePod {index}/{total}: identifiant manquant, ignoré.")
            continue
        room = prompt_room_for_homepod(index, total, snapshot, prompt_fn=prompt_fn)
        assignments.append((device_id, room))
    return build_rooms_mapping(assignments)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a local rooms.json by reading live HomePod sensors."
    )
    parser.add_argument(
        "-f",
        "--pairing-file",
        required=True,
        help="Path to the existing pairing.json (not modified).",
    )
    parser.add_argument(
        "-o",
        "--output",
        default=DEFAULT_OUTPUT,
        help=f"Output rooms.json path (default: {DEFAULT_OUTPUT}).",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_HOMEKIT_TIMEOUT_SECONDS,
        help="HomeKit timeout in seconds.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    socket.setdefaulttimeout(args.timeout)
    controller = load_controller(args.pairing_file)
    pairings = controller.get_pairings()
    snapshots: list[dict[str, Any]] = []
    print(f"HomePods chargés: {len(pairings)}")
    print("Les paires stéréo ne sont pas exposées par HAP; association un par un.")
    for alias, pairing in pairings.items():
        print(f"Lecture de {alias}…")
        snapshots.append(collect_snapshot(alias, pairing))
        close_pairing(pairing)

    mapping = assign_rooms(snapshots)
    if not mapping:
        print("Aucun mapping à écrire.", file=sys.stderr)
        return 1
    output = str(Path(args.output).expanduser())
    overwrite = False
    if Path(output).exists():
        if not confirm_overwrite(output):
            print("Abandon, fichier existant conservé.")
            return 1
        overwrite = True
    write_rooms_file(output, mapping, overwrite=overwrite)
    print(f"Écrit {len(mapping)} association(s) dans {output} (mode 600).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
