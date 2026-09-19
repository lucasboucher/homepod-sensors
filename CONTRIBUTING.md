# Contributing

## Secrets

Do not commit `pairing.json`, dumps, certificates, `.env` files, endpoint URLs,
or any real HomeKit keys. Use the placeholder files in `collector/` as the
template for examples.

Do not paste those files into pull requests or issue comments. See
[SECURITY.md](SECURITY.md).

## Scope

- Keep the extractor behavior intact. Do not simplify or remove the SIP/AMFI
  workflow, entitlements, or vendored sources.
- The collector should keep using `homekit[IP]` and should only read
  temperature and humidity unless a change is explicitly about new HAP
  characteristics.

## Tests you can run without secrets

From the repository root:

```bash
python3 -m py_compile collector/app.py
python3 -m unittest collector/test_schedule.py

cd extractor
swift build
.build/arm64-apple-macosx/debug/HomePodKeychainExtractor --help
```

Do not run extraction or collector pairing tests in CI against real HomePods
from this repository. Those require local secrets.
