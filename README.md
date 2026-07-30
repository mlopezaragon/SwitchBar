# SwitchBar

[![CI](https://github.com/mlopezaragon/SwitchBar/actions/workflows/ci.yml/badge.svg)](https://github.com/mlopezaragon/SwitchBar/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/mlopezaragon/SwitchBar?include_prereleases)](https://github.com/mlopezaragon/SwitchBar/releases)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2026-lightgrey)

Native macOS menu bar app that shows live usage for several Claude Code
accounts and switches the active account — with one click, or automatically
when a usage window fills up.

> **Unofficial project.** SwitchBar is independent and is not affiliated
> with, endorsed by, or supported by Anthropic. "Claude" and "Claude Code"
> are trademarks of Anthropic, PBC.

[Versión en español](README.es.md)

## Features

- Usage bars per account: 5-hour window, weekly window, and the separate
  Opus/Fable weekly quota, each with its reset time.
- One-click switching of the active Claude Code account, with undo.
- Automatic switching with independent, configurable thresholds per window.
- Shared accounts: set a personal cap (for example 70 %) so the app treats
  the account as exhausted early and leaves margin for the other person.
- Anthropic public status (status.claude.com) shown during incidents, so a
  server-side outage is never confused with a local problem.
- Pauses automatic switching for 15 minutes after you pick an account by
  hand with `/login` — your explicit choice wins.
- Localized in 10 languages. No telemetry of any kind.

## Requirements

- macOS 26 (Tahoe), Apple Silicon or Intel (universal binary).
- [Claude Code](https://code.claude.com) with one or more Claude
  subscription accounts (Pro/Max).

## Install

With [Homebrew](https://brew.sh):

```sh
brew install --cask mlopezaragon/tap/switchbar
```

Or manually: download `SwitchBar-<version>.dmg` from
[Releases](../../releases), verify its published SHA-256
(`shasum -a 256 SwitchBar-<version>.dmg`) and drag SwitchBar to
Applications.

Beta builds are Developer ID signed but not yet notarized: the first time
you open the app, right-click it and choose "Open". The stable release
will be notarized and open without any prompt.

Then click "Add account", sign in once with the official
`claude auth login --claudeai` flow, and repeat per account. From then on,
switching never asks for a password or another login while the session
remains valid.

## How it works — read this before relying on it

SwitchBar talks to the same private endpoints that Claude Code itself uses
(the usage endpoint and the standard OAuth refresh flow, with Claude Code's
own public client id). **These endpoints are not a documented, stable public
API.** Anthropic may change or restrict them at any time. SwitchBar is
designed to fail safely when that happens — it keeps the last known data,
never corrupts your Claude Code session, and marks accounts that need a new
login — but no permanent compatibility can be promised.

Login itself always happens through the official Claude Code flow in your
terminal and browser; SwitchBar never sees your password and never performs
an OAuth authorization on its own.

## Security model

- Claude Code keeps its official session in its own Keychain entry and
  `~/.claude.json`. SwitchBar only replaces the `claudeAiOauth` and
  `oauthAccount` blocks when switching; MCP credentials and every other key
  are preserved.
- Saved profiles live in a single private Keychain entry owned by
  SwitchBar; `profiles.json` holds only non-secret metadata (mode 0600).
- Keychain access goes through `/usr/bin/security` — the same mechanism
  Claude Code uses — and never widens an entry's ACL.
- The active account's credential lifecycle is owned by Claude Code:
  SwitchBar never rotates its token, so open terminals are never
  invalidated. Only inactive profiles (which no terminal is using) are
  refreshed, and the rotated token is stored back in the private vault.

## Privacy

SwitchBar sends network requests exclusively to:

- `api.anthropic.com` — read-only usage query per account.
- `console.anthropic.com` — standard OAuth token refresh for inactive
  profiles.
- `status.claude.com` — public status page (no credentials attached).

Nothing else leaves your Mac. There is no telemetry, no analytics, no
crash reporting, and no third-party server. See [PRIVACY.md](PRIVACY.md).

## Build from source

```sh
make test      # run the test suite
make app       # build and sign SwitchBar.app (universal)
make install   # copy to /Applications
make dmg       # distribution DMG with SHA-256
```

Building requires a stable signing identity (Developer ID or a local
self-signed certificate); see `scripts/build-app.sh`. The Keychain ties the
private profile vault to the code signature, so an ad-hoc signature would
re-prompt for authorization after every rebuild.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: please follow
[SECURITY.md](SECURITY.md) instead of opening a public issue.

## License

[Apache 2.0](LICENSE). Copyright 2026 Manuel Lopera.
