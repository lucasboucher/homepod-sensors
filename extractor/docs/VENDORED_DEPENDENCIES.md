# Vendored dependencies

The original `pvieito` packages are not publicly cloneable. This project vendors
local copies of historically recovered sources where available.

## FoundationKit

| Item | Detail |
|------|--------|
| **Original** | `git@github.com:pvieito/FoundationKit.git` |
| **Source** | `hcavillones/FoundationKit` (faithful public mirror of pvieito) |
| **Commit** | `cc432cfb9fc7eff6156cffa3c982eedc86805b0e` |
| **Provenance** | Historically reliable copy of pvieito FoundationKit |
| **Source pin** | `cc432cfb` — see [SOURCE_PINS.md](SOURCE_PINS.md#foundationkit) |
| **Status** | **Historical source restored** |
| **Active copy** | `Vendored/FoundationKit/` |
| **Dependency** | None (historical) |
| **Tests** | `Vendored/FoundationKit/Tests/FoundationKitTests/` (historical, 9 test files) |

The May 2026 minimal reconstruction (7 extension files) was replaced because
it only covered APIs used by KeychainKit and CodeSignKit. The restored source
contains the full historical library (37 Swift files) including `Process.runReplacingCurrentProcess` with `posix_spawn` and `responsibility_spawnattrs_setdisclaim`, and `Process(executableName:)` using `ProcessInfo.executableDirectories`.

Restored source is byte-faithful to hcavillones/FoundationKit @ `cc432cfb`; only SwiftPM
paths differ (`Sources/FoundationKit/`, `Tests/FoundationKitTests/`). The original
`FoundationKitMac` symlink to `FoundationKit` is represented by both targets
pointing at `Sources/FoundationKit`.

## LoggerKit

| Item | Detail |
|------|--------|
| **Original** | `git@github.com:pvieito/LoggerKit.git` |
| **Source** | `kongzii/LoggerKit` (faithful public mirror of pvieito) |
| **Commit** | `9b54626f` |
| **Source pin** | `9b54626` — see [SOURCE_PINS.md](SOURCE_PINS.md#loggerkit) |
| **Status** | **Historical source restored** |
| **Active copy** | `Vendored/LoggerKit/` |
| **Dependency** | Rainbow `from: "3.0.0"` (historical) |
| **Tests** | `Vendored/LoggerKit/Tests/LoggerKitTests/` (historical, 10-level filtering) |

The May 2026 minimal reconstruction was replaced because it dropped historical
APIs (`LogLevel` cases 0–9, `LogMode.logger`/`customLogger`, `error`/`warning`/
`notice`/`action`, `LOGGERKIT_EXTENDED_LOG`, deprecated helpers) and changed
behaviour (prefixes, stderr vs stdout, filtering at `.info`).

Restored source is byte-faithful to kongzii/LoggerKit @ `9b54626f`; only SwiftPM
paths differ (`Sources/LoggerKit/`, `Tests/LoggerKitTests/`).

## AuthenticationKit

| Item | Detail |
|------|--------|
| **Original** | `git@github.com:pvieito/AuthenticationKit.git` (local path dep in commit 806e44f) |
| **Status** | Repository not found |
| **Replacement** | `Vendored/AuthenticationKit/` |
| **Reconstruction basis** | KeychainKit commit `806e44f^` (`LAContext.evaluatePolicy`) and `806e44f` (`DeviceOwnerAuthenticator().grant()`) |
| **API reproduced** | `DeviceOwnerAuthenticator`, `grant()` |

The original AuthenticationKit source was not recovered. The reconstruction uses
`LocalAuthentication.LAContext` with `deviceOwnerAuthentication` policy, matching
the pre-CodeSignKit flow documented in git history.

## CodeSignKit

| Item | Detail |
|------|--------|
| **Original** | `git@github.com:pvieito/CodeSignKit.git` |
| **Source** | `seydx/CodeSignKit` |
| **Commit** | `08c2f311` |
| **Provenance** | Explicit merge of `pvieito:master` (2024-08-02) |
| **Status** | **Historical source restored** |
| **Source pin** | `08c2f311` — see [SOURCE_PINS.md](SOURCE_PINS.md#codesignkit) |
| **Active copy** | `Vendored/CodeSignKit/` |
| **File** | `Sources/CodeSignKit/CodeSign.swift` |
| **Historical reference** | `itavero/CodeSignKit` @ `159be91f` (2019-12-09, introduction KeychainKit) |

Public API preserved:

```swift
CodeSign.sign(at:identity:entitlementsURL:force:)
CodeSign.signMainExecutableOnceAndRun(entitlementsURL:_filePath:)
```

Environment variable: `CODESIGNKIT_DEFAULT_IDENTITY`
