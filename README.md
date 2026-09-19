# HomePod sensors

Read HomePod temperature and humidity over HomeKit Accessory Protocol (HAP)
without resetting the speakers or pairing them again.

Apple HomePods do not support the usual third-party HomeKit pairing flow.
The pairing keys already stored in the macOS keychain can be reused so any
program can talk to the accessories over HAP.

```text
macOS Keychain          →  extractor  →  pairing material (keep private)
HomePods over HAP       →  collector  →  temperature + humidity JSON
JSON                    →  any consumer you choose
```

## What this project does

1. **Extractor (macOS)** — reads HomeKit pairing identity and paired accessory
   keys from the keychain (`com.apple.hap.pairing`).
2. **Collector (Linux/Docker)** — uses that local pairing file to poll
   temperature and humidity from HomePods over HAP (`homekit[IP]`).
3. **Output** — a small JSON document you can consume however you want.

The pairing file is the technical product of the extractor. The JSON readings
are the technical product of the collector. Neither component is tied to a
particular automation platform.

## Why key extraction is required

HomePods in Apple Home are already paired with the Apple Home hub/controller.
Third-party software cannot complete a fresh HAP pairing with a HomePod the
way it can with many other accessories. Resetting the speaker to pair it
elsewhere breaks the Apple Home setup.

The extractor recovers the existing controller keys from macOS so HAP clients
can authenticate as that already-paired controller.

Temporarily disabling SIP and AMFI is required for that keychain access.
Restore them afterwards. Treat dumps and `pairing.json` as private keys.
See [SECURITY.md](SECURITY.md).

## How the data can be consumed

After extraction you have a `pairing.json` (local, never committed). From
there you can:

- run the collector, which POSTs JSON to any HTTP endpoint
- point a custom script at the same pairing file with `homekit[IP]`
- feed the pairing material into another HAP client
- write the JSON to a file, MQTT bridge, or database from your own code

The collector only knows “POST this JSON to `HTTP_ENDPOINT_URL`”. What sits
behind that URL is up to you.

### Integration examples

These are examples, not requirements:

| Consumer | How it typically uses this project |
|----------|------------------------------------|
| Custom HTTP service | Collector POSTs to your endpoint |
| n8n, Make, Zapier, … | Collector POSTs to a webhook URL |
| Home Assistant | Optional: import pairing keys into `homekit_controller` (see extractor README). Not used by the collector. |
| A local script | Call `homekit.get_accessories` / HAP yourself with `pairing.json` |

## Warning

`pairing.json` and extractor dumps contain HomeKit private keys. They must
never be committed, copied into a Docker image, or pasted into GitHub issues.

You follow the SIP/AMFI steps at your own risk. See the disclaimer below.

## Requirements

- a Mac signed into the same Apple Home as the HomePods, with Xcode
- HomePods that already expose temperature and humidity in Apple Home
- for the collector: a Linux host on the same LAN (Raspberry Pi is typical)
  and Docker with host networking
- an HTTP endpoint if you want the collector to POST readings (any service
  that accepts a JSON POST)

## Layout

```text
homepod-sensors/
├── README.md                 # this file — start here
├── SECURITY.md
├── LICENSE
├── NOTICE.md
├── CONTRIBUTING.md
├── extractor/                # macOS Keychain → HomeKit pairing keys
│   ├── Package.swift
│   ├── Sources/
│   ├── Vendored/
│   ├── scripts/
│   ├── docs/
│   └── README.md
├── collector/                # HAP client → temperature/humidity JSON
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── app.py
│   ├── pairing.example.json
│   ├── env.example
│   └── README.md
└── .gitignore
```

## End-to-end

### 1. Clone

```bash
git clone <this-repository-url>
cd homepod-sensors
```

### 2. Extract pairing keys on the Mac

This step lowers macOS security briefly (SIP + AMFI), dumps
`com.apple.hap.pairing` items from the keychain, then you restore security.

```bash
cd extractor
./scripts/01-check-environment.sh --build
./scripts/02-extract-homepod-keys.sh start --confirm
```

Follow the script prompts and [extractor/docs/OPERATIONS.md](extractor/docs/OPERATIONS.md).
RecoveryOS steps (`csrutil disable` / `csrutil enable`) stay manual.

Successful extraction writes a dump under `extractor/.run/dump/` on the Mac.
That directory is gitignored.

You need:

- Xcode, with command-line tools selected:
  `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`
- an Apple Development signing certificate in Keychain Access
- Swift tools compatible with `extractor/Package.swift` (`swift-tools-version:6.2`)

Full extractor reference: [extractor/README.md](extractor/README.md).

### 3. Build `pairing.json` locally

Do this outside git. Copy [collector/pairing.example.json](collector/pairing.example.json)
and fill it from the dump.

Each accessory is one top-level alias that **you** choose. The collector
discovers every accessory in the file.

From the dump you need, per accessory:

- HomeKit pairing identity: `iOSPairingId`, `iOSDeviceLTPK`, `iOSDeviceLTSK`
- paired accessory: `AccessoryPairingID`, `AccessoryLTPK`
- reachable address: `AccessoryIP`, `AccessoryPort`, `Connection: "IP"`

How those fields appear in the dump:

```text
[*] HomeKit Pairing Identity (com.apple.hap.pairing)
[ ] Account: <iOSPairingId>
[ ] Key: "<iOSDeviceLTPK>+<iOSDeviceLTSK>"

[*] Paired HomeKit Accessory: XX:XX:XX:XX:XX:XX (com.apple.hap.pairing)
[ ] Account: <AccessoryPairingID>
[ ] Key: "<AccessoryLTPK>"
```

Optional HAP check (Python 3.11; do not commit the venv or pairing file):

```bash
python3 -m venv /tmp/homekit-venv
source /tmp/homekit-venv/bin/activate
python3 -m pip install "homekit[IP]==0.19.0"
python3 -m homekit.get_accessories -f /path/to/pairing.json -a '<DeviceAlias>'
```

`homekit[IP]` does not install cleanly on Python 3.13.

### 4. Collect temperature and humidity

On a Linux host on the same LAN as the HomePods:

```bash
docker build -t homepod-collector ./collector

docker run --rm \
  --network host \
  -e HTTP_ENDPOINT_URL="https://example.invalid/homepod-readings" \
  -e POLL_INTERVAL_SECONDS=60 \
  -v /absolute/path/to/pairing.json:/app/pairing.json:ro \
  homepod-collector
```

`HTTP_ENDPOINT_URL` is any URL that accepts `POST` with `Content-Type: application/json`.
Host networking is required so the container can reach HomePods on the LAN
(including HAP/Bonjour if an address in the pairing file is stale).

Any Docker host or orchestrator can run this image the same way (compose,
systemd, Dokploy, …). Do not bake `pairing.json` or the endpoint URL into
the image.

Full collector reference: [collector/README.md](collector/README.md).

### 5. JSON payload

The collector POSTs:

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

- `timestamp` is UTC, generated by the collector
- numbers are JSON numbers, not strings
- HomeKit keys, pairing IDs, and IPs are not included
- an accessory that fails in a cycle is omitted from `sensors`

## Collector environment

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PAIRING_FILE` | no | `/app/pairing.json` | Path to the runtime pairing file |
| `HTTP_ENDPOINT_URL` | **yes** | none | URL that receives the JSON POST |
| `POLL_INTERVAL_SECONDS` | no | `60` | Seconds between collection cycles |
| `HOMEKIT_TIMEOUT_SECONDS` | no | `15` | Timeout for one HomeKit attempt |
| `HTTP_TIMEOUT_SECONDS` | no | `10` | Timeout for one HTTP POST |

`WEBHOOK_URL` and `N8N_WEBHOOK_URL` are accepted as aliases of
`HTTP_ENDPOINT_URL`. `N8N_TIMEOUT_SECONDS` is an alias of
`HTTP_TIMEOUT_SECONDS`. Prefer the generic names.

See [collector/env.example](collector/env.example). Never commit a filled
`.env`.

## What this project does not do

- It does not pair new HomePods from scratch.
- It does not reset HomePods.
- It does not collect audio, volume, playback, Siri, or switches.
- It does not require any specific automation platform.

## Disclaimer

YOU FOLLOW THESE INSTRUCTIONS AT YOUR SOLE RISK. THIS PROJECT IS PROVIDED
"AS-IS", WITHOUT WARRANTY OF ANY KIND. THE AUTHORS ARE NOT LIABLE FOR DATA
LOSS, DEVICE DAMAGE, OR SECURITY IMPACT FROM DISABLING SIP/AMFI OR FROM
HANDLING HOMEKIT KEYS.

Disabling System Integrity Protection and AMFI weakens the Mac until you
restore them. Re-enable both after extraction. Connecting to a network with
working Internet access is required before `csrutil enable` in RecoveryOS.

## Provenance

The extractor is based on public work:

- [pvieito/KeychainKit](https://github.com/pvieito/KeychainKit)
- [pseudorandomuser/KeychainKit](https://github.com/pseudorandomuser/KeychainKit)
- [mattrohr/homepod-sensors-homeassistant](https://github.com/mattrohr/homepod-sensors-homeassistant)

Vendored historical sources and commit pins:
[extractor/docs/SOURCE_PINS.md](extractor/docs/SOURCE_PINS.md),
[NOTICE.md](NOTICE.md).

The collector uses [homekit_python](https://github.com/jlusiardi/homekit_python)
0.19.0 with the `[IP]` extra.

## License

MIT for original project files. Vendored extractor libraries keep their
upstream copyright notices. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
