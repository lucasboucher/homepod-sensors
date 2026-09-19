# Source pins

Historical commit identifiers and upstream repositories used to reconstruct this
project. Active code lives under `Sources/` and `Vendored/`. Detailed vendoring
notes are in [VENDORED_DEPENDENCIES.md](VENDORED_DEPENDENCIES.md).

This document replaces the former `refs/` directory of local historical snapshots.
No source copies are kept in-tree; use the repository URLs and commits below to
inspect upstream history.

## Summary

| Source | Commit (when known) | Role | Active location |
|--------|---------------------|------|-----------------|
| [mattrohr/homepod-sensors-homeassistant](https://github.com/mattrohr/homepod-sensors-homeassistant) | `94f795a` | Functional reference for extraction workflow and KeychainTool flow | `Sources/HomePodKeychainExtractor/` |
| [pvieito/KeychainKit](https://github.com/pvieito/KeychainKit) | `bbe7e52` | Original KeychainKit library and CLI structure | `Sources/KeychainKit/` |
| [pseudorandomuser/KeychainKit](https://github.com/pseudorandomuser/KeychainKit) | unknown | `com.apple.hap.pairing` entitlement and HomeKit README lineage | `Sources/HomePodKeychainExtractor/HomePodKeychainExtractor.entitlements`, docs |
| [hcavillones/FoundationKit](https://github.com/hcavillones/FoundationKit) | `cc432cfb9fc7eff6156cffa3c982eedc86805b0e` | Restoration source for pvieito FoundationKit | `Vendored/FoundationKit/` |
| [kongzii/LoggerKit](https://github.com/kongzii/LoggerKit) | `9b54626f` | Restoration source for pvieito LoggerKit | `Vendored/LoggerKit/` |
| [seydx/CodeSignKit](https://github.com/seydx/CodeSignKit) | `08c2f311` | `signMainExecutableOnceAndRun` auto-sign workflow | `Vendored/CodeSignKit/` |
| pvieito AuthenticationKit (historical) | `806e44f` (introduction in KeychainKit history) | Historical `DeviceOwnerAuthenticator`; **not on active extract path** | `Vendored/AuthenticationKit/` |

---

## Functional reference — mattrohr/homepod-sensors-homeassistant

| Field | Value |
|-------|-------|
| **Repository** | https://github.com/mattrohr/homepod-sensors-homeassistant |
| **Commit** | `94f795a` |
| **Role** | Functional reference for KeychainTool behaviour and the SIP/AMFI → extract → restore workflow |
| **Active implementation** | `Sources/HomePodKeychainExtractor/ExtractCommand.swift`, `docs/OPERATIONS.md` |

The mattrohr extraction path is:

`Logger.logMode = .commandLine` → `Logger.logLevel = .debug` (forced) →
`CodeSign.signMainExecutableOnceAndRun()` → `Keychain.system.getItems(...)` →
`Logger.log(important: "Keychain Items Matched: …")` → `printDetails()` per item.

Historical files consulted during reconstruction (no longer vendored locally):
`KeychainTool/main.swift`, `Package.swift`, `README.md` from the repository above
at commit `94f795a`.

Home Assistant `core.config_entries` schema notes originated in the mattrohr
README; see the upstream repository README at commit `94f795a`.

---

## KeychainKit — pvieito/KeychainKit

| Field | Value |
|-------|-------|
| **Repository** | https://github.com/pvieito/KeychainKit |
| **Commit** | `bbe7e52` |
| **Role** | Original historical KeychainKit implementation and CLI structure |
| **Active implementation** | `Sources/KeychainKit/` |

Upstream CLI contrast (documented from historical audit): pvieito KeychainTool used
`verbose ? .debug : .info` for log level; the active mattrohr-aligned path forces
`.debug` in `ExtractCommand.swift`.

---

## KeychainKit — pseudorandomuser/KeychainKit

| Field | Value |
|-------|-------|
| **Repository** | https://github.com/pseudorandomuser/KeychainKit |
| **Commit** | unknown |
| **Role** | `com.apple.hap.pairing` entitlement and HomeKit-oriented README / operational guide |
| **Active implementation** | `Sources/HomePodKeychainExtractor/HomePodKeychainExtractor.entitlements`, operational documentation |

Exact commit pin not recorded in this repository.

---

## FoundationKit — hcavillones/FoundationKit

| Field | Value |
|-------|-------|
| **Repository** | https://github.com/hcavillones/FoundationKit |
| **Commit** | `cc432cfb9fc7eff6156cffa3c982eedc86805b0e` |
| **Role** | Restoration source for pvieito FoundationKit |
| **Active implementation** | `Vendored/FoundationKit/` |

See [VENDORED_DEPENDENCIES.md](VENDORED_DEPENDENCIES.md#foundationkit).

---

## LoggerKit — kongzii/LoggerKit

| Field | Value |
|-------|-------|
| **Repository** | https://github.com/kongzii/LoggerKit |
| **Commit** | `9b54626f` |
| **Role** | Restoration source for pvieito LoggerKit |
| **Active implementation** | `Vendored/LoggerKit/` |

See [VENDORED_DEPENDENCIES.md](VENDORED_DEPENDENCIES.md#loggerkit).

---

## CodeSignKit — seydx/CodeSignKit

| Field | Value |
|-------|-------|
| **Repository** | https://github.com/seydx/CodeSignKit |
| **Commit** | `08c2f311` |
| **Role** | Reproduce historical auto-sign workflow (`signMainExecutableOnceAndRun`) |
| **Active implementation** | `Vendored/CodeSignKit/` |
| **Earlier introduction** | `itavero/CodeSignKit` @ `159be91f` (2019-12-09, KeychainKit integration) |

See [VENDORED_DEPENDENCIES.md](VENDORED_DEPENDENCIES.md#codesignkit).

---

## AuthenticationKit — pvieito (historical)

| Field | Value |
|-------|-------|
| **Original** | `git@github.com:pvieito/AuthenticationKit.git` (local path dependency in KeychainKit history) |
| **Commit `806e44f`** | Introduced external `AuthenticationKit` and `DeviceOwnerAuthenticator().grant()` in KeychainTool |
| **Commit `6ba9dc6`** | Removed `DeviceOwnerAuthenticator` from KeychainTool (same day as `806e44f`; never present in mattrohr) |
| **Active implementation** | `Vendored/AuthenticationKit/` (reconstructed from git history; upstream repository not publicly recoverable) |

**Not on the active extraction path.** `DeviceOwnerAuthenticator` is preserved as
historical provenance only. The current extract flow follows the final mattrohr
workflow: no device-owner authentication step before keychain access.

See [VENDORED_DEPENDENCIES.md](VENDORED_DEPENDENCIES.md#authenticationkit).
