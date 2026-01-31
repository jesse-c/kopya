# Kopya

<!--toc:start-->
- [Intro](#intro)
- [Features](#features)
- [Config](#config)
  - [Regex Filtering](#regex-filtering)
- [Install](#install)
- [Clients](#clients)
- [Releasing](#releasing)
<!--toc:end-->

---

> [!WARNING]
> This is an alpha version. I am using it daily though.

---

## Intro

This is a headless/daemon-only clipboard manager[^1]. By itself, it's not useful, without a [client](#clients).

It exposes a REST API over HTTP. You can list, search, and delete entries.

You can read my introductory blog post[^2].

## Features

- Store your clipboard entries over time
- Limit how many are stored, with a rolling clean-up window
- Private Mode: Disable clipboard monitoring, and optionally re-enable after a set time, or at and end time
- Content filtering: Skip storing sensitive data matching regex patterns
- Run at login (when installed as .app bundle)
- Optional: Backup hourly

## Config

There must be a config file at `$USER/.config/kopya/config.toml`, with contents like the following:

```toml
run-at-login = true
max-entries = 10000000
port = 9090

[backup]
interval = 86400  # 24 hours in seconds (default)
count = 2         # Number of backups to keep (default)

filter = true
filters = [
  "password\\w*",
  ".*token.*",
  ".*api_?key.*",
  ".*secret.*",
  "\\b\\d{4}[- ]?\\d{4}[- ]?\\d{4}[- ]?\\d{4}\\b"  # Credit card pattern
]
```

### Regex Filtering

Kopya supports filtering clipboard content based on Swift's native Regex patterns. When enabled, any clipboard content matching one of your filter patterns will be detected but not stored, helping protect sensitive information.

- Enable filtering with `filter = true`
- Define patterns with `filters = [...]`
- If `filter = true` but no filters are provided, no content will be filtered

## Install

### Via .app Bundle (Recommended)

1. Download `Kopya.app.zip` from [releases](https://github.com/jesse-c/kopya/releases/latest)
2. Unzip and drag `Kopya.app` to `/Applications/`
3. Launch Kopya.app (double-click or `open /Applications/Kopya.app`)
4. Create config file at `~/.config/kopya/config.toml` (see [Config](#config))

The app runs in the background (no Dock icon). Set `run-at-login = true` in config to start automatically at login.

**CLI Access (Optional)**

For command-line access, create a symlink:

```bash
ln -s /Applications/Kopya.app/Contents/MacOS/kopya /usr/local/bin/kopya
```

Or use the `just` command:

```bash
just link-cli
```

### Building from Source

#### .app

```bash
# Build .app bundle
just build-app

# Install to /Applications
just install-app

# Optional: Create CLI symlink from installed .app
just link-cli
```

#### CLI-only (Legacy)

```bash
# Build CLI binary
just build-cli

# Install to ~/.local/bin
just install-cli
```

> [!NOTE]
> `run-at-login` requires the .app bundle.

## Clients

- Raycast extension: [WIP](https://github.com/jesse-c/extensions/tree/feat/add-kopya/extensions/kopya)
- Emacs package: [WIP](https://github.com/jesse-c/dotfiles/blob/main/home/dot_config/emacs/user/kopya.el)

## Releasing

Releases are created using the CD workflow via GitHub Actions:

1. Commit your changes using [conventional commits](https://www.conventionalcommits.org/):

   | Type | Description | Version Bump |
   |------|-------------|--------------|
   | `feat` | New feature | MINOR |
   | `fix` | Bug fix | PATCH |
   | `refactor` | Code refactoring | none |
   | `chore` | Maintenance tasks | none |
   | `docs` | Documentation changes | none |
   | `ci` | CI/CD changes | none |
   | `build` | Build system changes | none |
   | `perf` | Performance improvements | none |
   | `test` | Test changes | none |
   | `style` | Code style changes | none |

   Examples:
   ```
   feat: add pagination to history endpoint
   fix: properly remove old backups
   refactor: group backup config together
   docs: improve install instructions
   ```

   For breaking changes, add `!` after the type or add `BREAKING CHANGE:` to the footer:
   ```
   feat!: change API endpoint structure
   feat: remove deprecated endpoint

   BREAKING CHANGE: this removes support for legacy clients
   ```

   > [!NOTE]
   > Commit messages are validated in CI on every push and PR. Non-conventional commits will fail the check.

2. Go to Actions → CD workflow in GitHub

3. Click "Run workflow" → Select branch → Click "Run"

   The workflow validates commits since the last release. If validation fails, you'll see an error like:
   ```
   Error: Missing commit type separator ':'
   Errored commit: abc123...
   Commit message: 'your invalid message'
   ```
   Fix the problematic commits and re-run the workflow.

4. The workflow will:
   - Bump version based on commits (cocogitto)
   - Generate changelog
   - Build CLI binary and .app bundle
   - Create GitHub release with tag
   - Attach `kopya` and `Kopya.app.zip`

[^1]: https://j-e-s-s-e.com/blog/multi-uis-for-a-daemon-and-using-grpc-to-communicate-locally-from-rust-swift
[^2]: https://j-e-s-s-e.com/blog/alpha-release-of-kopya
