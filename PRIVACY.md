# Privacy

SwitchBar runs entirely on your Mac. This document describes exactly what
it reads, what it stores, and what it sends.

## What it reads

- `~/.claude.json` — only the `oauthAccount` block (account id, e-mail,
  display name), to know which account is active in Claude Code.
- The "Claude Code-credentials" Keychain entry — only when you switch or
  capture an account, through `/usr/bin/security`.

## What it stores, locally only

- One private Keychain entry with the OAuth tokens of the accounts you
  saved. Access is tied to the app's code signature.
- `~/Library/Application Support/ClaudeSwitch/profiles.json` — non-secret
  metadata (e-mail, account id, preferences), file mode 0600. The folder
  keeps the project's historical name so upgrades keep existing data.
- App preferences (thresholds, polling interval) in standard macOS user
  defaults.

## What it sends, and to whom

| Destination | Purpose | Credentials |
|---|---|---|
| `api.anthropic.com` | Read-only usage query | The account's own OAuth token |
| `console.anthropic.com` | Standard OAuth token refresh for inactive profiles | The account's own refresh token |
| `status.claude.com` | Public service status | None |

There is no telemetry, no analytics, no crash reporting, and no server of
ours. SwitchBar never transmits your tokens, e-mail, or usage data to any
third party.

## What it never does

- It never sees or asks for your Claude password: login always happens in
  the official Claude Code flow.
- It never widens Keychain ACLs or exports secrets.
- It never phones home.
