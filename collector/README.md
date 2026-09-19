# HomePod collector

Reads temperature and humidity from already-paired HomePods over HAP
(`homekit[IP]==0.19.0`) and POSTs a JSON payload to a configurable HTTP
endpoint.

The collector does not extract keys. It uses a runtime `pairing.json`
produced on a Mac with the extractor and mounted into the container.

It has no dependency on a particular automation platform. The HTTP URL can
be your own service, a webhook, n8n, or anything else that accepts JSON.

## What it does

```text
HomePods
    → HAP / homekit[IP]
    → temperature + humidity
    → HTTP POST (JSON)
    → whatever you point HTTP_ENDPOINT_URL at
```

Accessories are discovered from the pairing file. Private HomeKit keys are
never hardcoded, logged, or included in the payload.

## Requirements

- Python 3.11 (the Docker image uses `python:3.11-slim`)
- Linux host on the same LAN as the HomePods
- Docker with `network_mode: host` (needed for LAN / HAP discovery)
- a local `pairing.json` that is **not** in git
- an HTTP endpoint that accepts `POST` + `application/json`

On macOS, Docker host networking is limited. Use a Linux host for a real
deployment.

## Build the image

From the repository root:

```bash
docker build -t homepod-collector ./collector
```

The image does not contain `pairing.json` or any secrets. See `.dockerignore`.

## pairing.json

Provide the pairing file at runtime with a bind mount. Inside the container
the default path is `/app/pairing.json`. Override with `PAIRING_FILE`.

Do not commit this file. Do not copy it into the image.

Template with placeholders only: [pairing.example.json](pairing.example.json).

```json
{
  "HomePod-1": {
    "AccessoryPairingID": "<AccessoryPairingID>",
    "AccessoryLTPK": "<AccessoryLTPK>",
    "iOSPairingId": "<iOSPairingId>",
    "iOSDeviceLTSK": "<iOSDeviceLTSK>",
    "iOSDeviceLTPK": "<iOSDeviceLTPK>",
    "AccessoryIP": "<IPv4Address>",
    "AccessoryPort": "<Port>",
    "Connection": "IP"
  }
}
```

The collector reads **every** accessory in that file. Choose aliases yourself
when you build the file from the extractor dump. IP addresses and ports come
from the pairing file. If an address is stale, `homekit[IP]` can fall back to
HAP discovery on the host network.

## Run

```bash
docker run --rm \
  --network host \
  -e HTTP_ENDPOINT_URL="https://example.invalid/homepod-readings" \
  -e POLL_INTERVAL_SECONDS=600 \
  -e PAIRING_FILE=/app/pairing.json \
  -v /absolute/path/to/pairing.json:/app/pairing.json:ro \
  homepod-collector
```

Replace the endpoint URL and pairing-file path with your local values.
Do not commit those values.

The pairing file is created locally and must never be committed. The collector
mounts it read-only at `/app/pairing.json`. The HTTP endpoint is generic: any
service that accepts the JSON POST. n8n and Home Assistant are only example
consumers.

## Docker Compose

[docker-compose.yaml](docker-compose.yaml) uses `network_mode: host` and mounts
the host pairing file at `/app/pairing.json:ro`.

Copy [env.example](env.example) to `.env` (gitignored):

```bash
cd collector
cp env.example .env
```

Set at least:

| Variable | Role |
|----------|------|
| `PAIRING_FILE_HOST` | Absolute path to your local `pairing.json` on the host |
| `HTTP_ENDPOINT_URL` | URL that receives `POST` + JSON |

Compose always sets `PAIRING_FILE=/app/pairing.json` inside the container.
Optional: `POLL_INTERVAL_SECONDS` (default 600, clock-aligned 10-minute
slots), `HOMEKIT_TIMEOUT_SECONDS` (default 15), `HTTP_TIMEOUT_SECONDS`
(default 10).

```bash
docker compose --env-file .env up --build
```

From the repository root (including Dokploy `--env-file collector/.env`):

```bash
docker compose --env-file collector/.env -f collector/docker-compose.yaml up --build
```

The image runs as uid 1000. The host pairing file must be readable by that
user (for example mode `644`). Do not make it world-writable.

The same flags work with Docker Compose, systemd, or any orchestrator that
can set host networking, environment variables, and a bind mount.

## Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PAIRING_FILE` | no | `/app/pairing.json` | Path to the runtime pairing file |
| `HTTP_ENDPOINT_URL` | **yes** | none | URL that receives the JSON POST |
| `POLL_INTERVAL_SECONDS` | no | `600` | Seconds between clock-aligned collection slots |
| `HOMEKIT_TIMEOUT_SECONDS` | no | `15` | Timeout for one HomeKit attempt |
| `HTTP_TIMEOUT_SECONDS` | no | `10` | Timeout for one HTTP POST |

Aliases (same meaning, prefer the names above):

- `WEBHOOK_URL`, `N8N_WEBHOOK_URL` → `HTTP_ENDPOINT_URL`
- `N8N_TIMEOUT_SECONDS` → `HTTP_TIMEOUT_SECONDS`

See [env.example](env.example). For Compose, also set `PAIRING_FILE_HOST`.
Never put real endpoint URLs or pairing data in git.

By default the collector runs every 10 minutes, aligned to the clock
(`00:00`, `00:10`, … `00:50` in UTC). It waits for the next multiple of
`POLL_INTERVAL_SECONDS` rather than sleeping that long after a cycle. If a
cycle overruns a slot, missed slots are skipped. Intervals that divide an
hour evenly stay on round clock times.

## JSON payload

```json
{
  "timestamp": "2026-09-19T12:00:00Z",
  "sensors": [
    {
      "name": "HomePod-1",
      "temperature_c": 23.1,
      "humidity_percent": 64
    }
  ]
}
```

- `timestamp` is generated by the collector in UTC at collection time
- numeric fields are JSON numbers, not strings
- HomeKit keys, pairing IDs, IPs, and ports are not included
- an accessory that fails during a cycle is omitted from `sensors`

Example consumers of this payload: a small HTTP receiver you write, n8n,
another webhook, or a script that logs the body.

## Logs

The process logs to stdout:

```text
INFO Starting HomePod collector
INFO Loaded 2 HomePods
INFO Collecting sensor data
INFO HomePod-1: temperature=23.1°C humidity=64%
INFO Sending 2 sensor readings
INFO Collection completed
```

```bash
docker logs -f <container>
```

Errors name the affected HomePod alias and never print `pairing.json`
contents or private keys. A failure on one HomePod or a temporary HTTP
error does not stop the collector.
