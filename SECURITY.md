# Security

This project handles HomeKit pairing material. Treat dumps and `pairing.json`
as private keys.

## Never commit or publish

- `pairing.json` or any copy of it
- `rooms.json` or any real room / Device ID mapping
- extractor dumps (`dump.txt`, `.run/dump/`)
- HomeKit private keys (`iOSDeviceLTSK`, `AccessoryLTPK`, and similar fields)
- Apple Development certificates, Team IDs, or signing identities
- HTTP endpoint / webhook URLs
- `.env` files
- environment-check reports from `extractor/scripts/01-check-environment.sh --report`

`.gitignore` already excludes pairing files, rooms files, dumps, `.run/`, `.env`, and reports.
That does not replace review before `git add`.

## Never paste into GitHub issues or chat

Redact secrets before asking for help. A useful report includes:

- macOS version and whether SIP/AMFI were changed
- `swift build` success or failure
- collector logs that name accessories, not keys
- HTTP status codes from your endpoint, not the endpoint URL

## Runtime handling

- Generate `pairing.json` on the Mac from extractor output.
- Keep it outside the git working tree when possible.
- Mount it read-only into the collector container.
- Do not copy it into the Docker image.
- Restore SIP and AMFI after extraction. See [extractor/docs/OPERATIONS.md](extractor/docs/OPERATIONS.md).

## Reporting a vulnerability

Do **not** open a public issue that contains pairing data, dumps, or keys.
Describe the issue without secrets. If you believe the repository itself
contains leaked credentials, say so without pasting them.
