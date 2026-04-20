# CCC

CCC is an open-source macOS utility for context-aware inline completions in arbitrary text fields using the local Codex CLI.

The repo is intentionally small:

- app source in `Sources/CCCApp`
- prompt templates in `Resources/Prompts`
- build and packaging scripts in `scripts`
- release support files in `Support`
- Codex plugin metadata in `.codex-plugin` and `skills`

## What the app does

- Runs as a lightweight macOS app with a small control window.
- Watches typing through a global event tap while the app is active.
- Requests a completion from the local Codex CLI when you type `ccc`.
- Shows a floating suggestion near the caret when possible, or near the mouse as fallback.
- Accepts the suggestion into the active app through paste-based injection.

## Shortcuts

- `ccc`: request a suggestion
- `Tab`: accept the visible suggestion
- `Shift+Tab`: retry and ask for another option
- `Escape`: dismiss the visible suggestion

## Requirements

- macOS 13+
- Codex desktop installed locally
- Swift 5.8+
- A usable Apple SDK

The supported build path is the repo scripts. `swift build` can work on machines with a full Xcode setup, but some Command Line Tools only installs fail to resolve the required macOS platform path.

## Local Development

Run the app locally:

```bash
scripts/run-local.sh
```

On first run the script creates `.local/config.toml` from `Support/config.example.toml`. That file is ignored by git and is the right place for local changes.

The script also keeps local runtime state under `.local/state/`, so session ids and dev-only config do not leak into the repo.

## Build And Package

Build a distributable `.app` bundle:

```bash
scripts/build-app.sh
```

Create a zip you can attach to a GitHub release:

```bash
scripts/package-release.sh
```

Install the built app into `~/Applications`:

```bash
scripts/install-app.sh
```

## Runtime Config

CCC looks for config in this order:

1. `CCC_CONFIG_FILE`
2. `~/Library/Application Support/CCC/config.toml`

For local repo development, `scripts/run-local.sh` sets `CCC_CONFIG_FILE` to `.local/config.toml`.

Supported keys:

```toml
codex_cli_path = "/Applications/Codex.app/Contents/Resources/codex"
model = "gpt-5.4"
# reasoning_effort = "minimal"
# user_name = "Your Name"
dev_mode = false
```

Defaults:

- `codex_cli_path` defaults to the standard Codex desktop bundle path when present
- `model` defaults to `gpt-5.4`
- `dev_mode` defaults to `false`

## Permissions

The app needs:

- Accessibility
- Input Monitoring
- Screen Recording when screenshot context is enabled

Without those, completion capture, anchoring, and screenshot-assisted context will degrade or fail.

## Logs

Logs are written to:

```bash
~/Library/Logs/CCC/ccc.log
```

## Codex Install Story

This repository is also shaped as a Codex-installable package. The plugin manifest lives at `.codex-plugin/plugin.json`, and the bundled `install-ccc` skill points Codex at the supported repo scripts:

- `scripts/run-local.sh`
- `scripts/build-app.sh`
- `scripts/package-release.sh`
- `scripts/install-app.sh`

That keeps the install story aligned with the actual source tree instead of adding duplicate scaffolding.

## Contributing

Collaborators are welcome. The ground rules are simple:

- keep the repo clean
- do not commit `.local`, `.build`, `dist`, screenshots, or session files
- prefer focused changes over broad refactors

See [CONTRIBUTING.md](/Users/roy.sadaka/Desktop/MachineLearning/research4/CONTRIBUTING.md) for the short contributor workflow.

## Current Limitations

- This is not a true IME.
- Existing editor context is limited unless Accessibility can read it.
- Paste-based insertion is less native than editor-specific integrations.
- Secure text fields are out of scope.
