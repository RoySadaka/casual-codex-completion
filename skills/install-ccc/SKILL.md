---
name: install-ccc
description: Build, package, or install the CCC macOS app from this repository using the supported repo scripts.
---

# CCC Install Workflow

Use this skill when the user wants to run CCC locally, create a release artifact, or install/update the app on their Mac.

## Supported entrypoints

- Local run: `scripts/run-local.sh`
- App bundle build: `scripts/build-app.sh`
- Zip artifact: `scripts/package-release.sh`
- Install into `~/Applications`: `scripts/install-app.sh`

## Guardrails

- Do not commit `.local/`, `.build/`, `dist/`, screenshots, or session state.
- Keep user-specific config in `.local/config.toml` or an explicit `CCC_CONFIG_FILE`, not tracked files.
- Call out required macOS permissions:
  - Accessibility
  - Input Monitoring
  - Screen Recording when screenshot context is enabled

## Output expectations

Report:

- which script was run
- whether it succeeded
- the artifact path or install location
- the top blocker if it failed
