# Notices

This repository includes original work and historically restored sources.

## Original work

Collector code, orchestration scripts, and project documentation are provided
under the MIT License. See `LICENSE`.

## Vendored extractor dependencies

Files under `extractor/Vendored/` are **not** covered by this repository's MIT
license. They are restored copies of historical libraries originally written
by Pedro José Pereira Vieito and recovered from public mirrors. Those files
keep their original copyright headers and terms.

Provenance and commit pins:

- [extractor/docs/VENDORED_DEPENDENCIES.md](extractor/docs/VENDORED_DEPENDENCIES.md)
- [extractor/docs/SOURCE_PINS.md](extractor/docs/SOURCE_PINS.md)

Upstream references include:

- [pvieito/KeychainKit](https://github.com/pvieito/KeychainKit)
- [pseudorandomuser/KeychainKit](https://github.com/pseudorandomuser/KeychainKit)
- [mattrohr/homepod-sensors-homeassistant](https://github.com/mattrohr/homepod-sensors-homeassistant)
- [hcavillones/FoundationKit](https://github.com/hcavillones/FoundationKit)
- [kongzii/LoggerKit](https://github.com/kongzii/LoggerKit)
- [seydx/CodeSignKit](https://github.com/seydx/CodeSignKit)

## Collector dependency

The collector uses [jlusiardi/homekit_python](https://github.com/jlusiardi/homekit_python)
(`homekit[IP]==0.19.0`), licensed separately as Apache-2.0.
