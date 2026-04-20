# Contributing

Contributions are welcome. Keep the repo tight.

## Expectations

- Prefer focused pull requests.
- Do not commit local runtime state, generated builds, or screenshots.
- Keep machine-specific config in `.local/` or user `Application Support`, not tracked files.
- Preserve the app's current scope unless the change clearly improves reliability, packaging, or editor compatibility.

## Local workflow

```bash
scripts/run-local.sh
```

For release artifacts:

```bash
scripts/build-app.sh
scripts/package-release.sh
```

If `swift build` is broken because the active Apple developer directory points at Command Line Tools only, use the scripts above or switch to a full Xcode installation with `xcode-select`.
