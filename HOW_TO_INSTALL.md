# How To Install CCC

CCC does not need a persistent Codex skill to be useful. It is a normal macOS app repo with a small set of supported scripts.

## Install For Local Use

Build and install the app into `~/Applications`:

```bash
scripts/install-app.sh
```

That script will:

- run preflight checks for `swiftc`, the macOS SDK, and required tooling
- build `dist/CCC.app`
- copy it into `~/Applications/CCC.app`
- run a post-install smoke test against the installed bundle

## Create A Release Artifact

Build a zip for sharing or GitHub Releases:

```bash
scripts/package-release.sh
```

Output:

- `dist/CCC-macos.zip`

## Uninstall

Remove the installed app, app support files, and logs:

```bash
scripts/uninstall-app.sh
```

## Run During Development

For local development:

```bash
scripts/run-local.sh
```

On first run this creates:

- `.local/config.toml`

That file is untracked.

## Config

Default local config template:

- `Support/config.example.toml`

Main keys:

```toml
codex_cli_path = "/Applications/Codex.app/Contents/Resources/codex"
model = "gpt-5.4"
dev_mode = false
```

Optional:

```toml
# reasoning_effort = "medium"
# user_name = "Your Name"
# prompt_prefix_char_limit = 4096
```

## Permissions

CCC may request:

- Accessibility
- Input Monitoring
- Screen Recording when screenshot context is enabled

## Why There Is No Install Skill

The install workflow is just documentation plus scripts. A Codex skill would persist in the user environment after install, even though CCC itself does not need an always-available Codex-side capability. Plain documentation is the cleaner choice here.
