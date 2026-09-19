# HomePod Keychain Extractor

This is the macOS extractor component. Run the commands below from this
directory (`extractor/`).

Extract HomeKit Pairing Identity and Paired HomeKit Accessory keys from the macOS
keychain so any HAP client can talk to already-paired HomePods without resetting
them.

The pairing file this component produces can be consumed by the collector in
this repository, by `homekit[IP]` scripts, or by other HAP clients. Home
Assistant and n8n are optional examples, not requirements.

This project merges:

- **pvieito/KeychainKit** — modern KeychainKit library and CLI structure
- **pseudorandomuser/KeychainKit** — `com.apple.hap.pairing` entitlement and HomeKit README
- **mattrohr/homepod-sensors-homeassistant** — Apple Silicon fixes, HA metadata, Python venv guide
- **Local prototype** — `probe` mode (minimal existence check)

## Modes

```bash
# Full extraction (requires SIP/AMFI changes and a valid signing identity)
swift run HomePodKeychainExtractor extract -g "com.apple.hap.pairing"

# Minimal probe — no secrets copied (original prototype behaviour)
swift run HomePodKeychainExtractor probe
```

## Status

| Component | Status |
|-----------|--------|
| KeychainKit (full) | ✅ Implemented |
| Probe mode | ✅ Implemented |
| LoggerKit | ✅ Restored from historical source |
| FoundationKit | ✅ Restored from historical source |
| AuthenticationKit / DeviceOwnerAuthenticator | ✅ Reconstructed from git history (not used in extract path) |
| CodeSignKit | ✅ Restored from historical source |

The project builds with Swift Package Manager and `--help` works. Access to
`com.apple.hap.pairing` requires the SIP/AMFI workflow in
[docs/OPERATIONS.md](docs/OPERATIONS.md). That is an OS constraint, not a
missing CodeSignKit feature.

See [docs/VENDORED_DEPENDENCIES.md](docs/VENDORED_DEPENDENCIES.md), [docs/SOURCE_PINS.md](docs/SOURCE_PINS.md), and [Vendored/CodeSignKit/README.md](Vendored/CodeSignKit/README.md).

## Orchestrated workflow

```bash
./scripts/01-check-environment.sh --build
./scripts/02-extract-homepod-keys.sh start --confirm
# RecoveryOS: csrutil disable → reboot → resume → reboot → resume → RecoveryOS: csrutil enable → reboot → resume
```

Details: [docs/OPERATIONS.md](docs/OPERATIONS.md)

## Operational guide

See [docs/OPERATIONS.md](docs/OPERATIONS.md) for SIP/AMFI procedure and extraction commands.

---

## Preamble

This repository along with the instructions in this document can be used to extract HomeKit Pairing Identity Keys along with Paired HomeKit Accessory Keys from macOS. These keys can be used in order to interact with your already paired HomeKit devices through third-party software, without needing to reset the device.

The collector in this repository is one consumer: it reads temperature and humidity over HAP and POSTs JSON to a configurable HTTP endpoint. You can also call `homekit[IP]` yourself, or feed the pairing material into another HAP client. Using the [Home Assistant HomeKit Device Integration](https://www.home-assistant.io/integrations/homekit_controller/) is one optional example of that last path.

If you do follow the Home Assistant example below, it is easily possible **to fully break your Home Assistant instance** by installing an invalid configuration file into your Home Assistant configuration's `.storage` directory, as these configuration files are normally **not intended to be edited manually**. Therefore, please make absolutely sure to backup your instance before proceeding, or at the very least to keep a copy of any unmodified files you extract from your `.storage` directory.

This guide uses a fork of the [KeychainKit](https://github.com/pvieito/KeychainKit) project, which contains some minor tweaks for it work on Apple Silicon machines running the most recent version of macOS.

## Disclaimer of Warranties

YOU EXPRESSLY AGREE THAT YOU ARE FOLLOWING THE BELOW INSTRUCTIONS AT YOUR SOLE RISK.\
THIS DOCUMENT IS PROVIDED "AS-IS", AND UNLESS OTHERWISE SPECIFIED IN WRITING,\
NO WARRANTIES OF ANY KIND ARE PROVIDED, NEITHER EXPRESS NOR IMPLIED.\
I WILL NOT BE HELD LIABLE FOR ANY POTENTIAL DATA LOSS OR DAMAGE DIRECTLY\
OR INDIRECTLY RESULTING FROM ANY OF THE DIRECTIONS GIVEN IN THIS DOCUMENT.

## Extract HomeKit Pairing Identity and Paired Accessory Keys

### Disable System Protections

* Boot your Mac into recoeryOS by shutting it down, holding the power button until "Loading Startup Options..." appears and choose the "Startup Options" entry.
* Within recoveryOS, open the Terminal via the "Utilities" menu bar section, disable System Integrity Protection and reboot.
```bash
$ csrutil disable
$ reboot
```
* Once back within macOS, disable Apple Mobile File Integrity and reboot.
```bash
$ sudo nvram boot-args="amfi_get_out_of_my_way=0x1"
$ sudo reboot
```

### Extract your Keys
* Ensure that the latest version of Xcode is installed and switch your active developer directory to your current installation.
```bash
$ sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```
* Fetch your code-signing certificate via Xcode account settings if it is not already present.
```
Xcode -> Settings... -> Accounts -> Manage Certificates -> (+) -> Apple Development
```
* Find your code-signing identity via Keychain Access, e.g. "Apple Development: appleid@example.com (FFFFFFFFFF)" and check its validity status.
  * If your certificate is shown as being invalid or not trusted, you will need to install the following two missing intermediate CA certificates:
    * Apple Worldwide Developer Relations Certificate Authority: https://developer.apple.com/certificationauthority/AppleWWDRCA.cer
    * Apple Worldwide Developer Relations Certificate Authority G3: https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
* Set the environment variable `CODESIGNKIT_DEFAULT_IDENTITY` to the name of your code-signing identity.
```bash
$ export CODESIGNKIT_DEFAULT_IDENTITY="Apple Development: appleid@example.com (FFFFFFFFFF)"
```
* Run HomePodKeychainExtractor to dump your keys:
```bash
$ mkdir dump
$ swift run HomePodKeychainExtractor extract -g "com.apple.hap.pairing" 1> dump/dump.txt 2>&1
```
* Proceed to the following sections only if the dump was successful and contains your keys, otherwise troubleshoot and try again.

### Restore System Protections
* Re-enable Apple Mobile File Integrity while still within macOS.
```bash
$ sudo nvram boot-args=""
$ sudo shutdown -h now
```
* Reboot into recoveryOS as outlined in the first step of the [Disable System Protections](#disable-system-protections) section.
* From within recoveryOS, re-enable System Integrity Protection and reboot.
  * Note: **It is required to connect to a network with a working Internet connection prior to re-enabling full system security.**
```bash
$ csrutil enable
$ reboot
```

### Install Python Dependencies Safely
Because macOS's Python environment is externally managed (e.g., by Homebrew), direct system-wide pip installs are disabled to protect your system. To safely install the homekit[IP] package, use a Python virtual environment:

> **Important:** The `homekit[IP]` package depends on the `ed25519` library, which currently is incompatible with Python 3.13 due to deprecated API usage. Attempting to install on Python 3.13 results in build errors.

To avoid this, use Python 3.11 or 3.10 to create your virtual environment:

```bash
pyenv install 3.11.8
pyenv local 3.11.8
python -m venv venv
source venv/bin/activate
python3 -V
python3 -m pip install --upgrade pip
python3 -m pip install "homekit[IP]"
```

### Discover HomeKit Devices on Network

```bash
$ python3 -m homekit.discover
```

### Extract Information from Dump

```
[*] HomeKit Pairing Identity (com.apple.hap.pairing)
[ ] Account: <iOSPairingId>
[ ] Key: "<iOSDeviceLTPK>+<iOSDeviceLTSK>"

[*] Paired HomeKit Accessory: XX:XX:XX:XX:XX:XX (com.apple.hap.pairing)
[ ] Account: <AccessoryPairingID>
[ ] Key: "<AccessoryLTPK>"
```

### Populate Python HomeKit Pairing Configuration

```json
{
  "<DeviceName>": {
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

### Test the Connection to the Devices

```bash
$ python3 -m homekit.get_accessories -f dump/pairing.json -a <DeviceName>
```

Keep `dump/pairing.json` outside git. You can then:

- run the collector in `../collector/` to poll temperature/humidity and POST JSON
  to any HTTP endpoint
- keep using `homekit[IP]` from a script
- feed the pairing file into another HAP client

See the repository root `README.md`.

### Optional example: Home Assistant

See full `core.config_entries` schema with `created_at`, `modified_at`, `discovery_keys`, and `subentries` in the [mattrohr/homepod-sensors-homeassistant](https://github.com/mattrohr/homepod-sensors-homeassistant) README (commit `94f795a`; see [docs/SOURCE_PINS.md](docs/SOURCE_PINS.md)). This is one possible consumer of the pairing keys, not a required part of this project.
