# Contributing to SwitchBar

Thank you for helping. A few ground rules keep the project safe to use.

## Setup

- macOS 26 (Tahoe) with the matching Xcode toolchain.
- `make build` compiles, `make test` runs the suite (no UI, no network:
  every network interaction is mocked with `URLProtocol`).
- `make app` needs a stable signing identity. For throwaway development
  builds you can use `SWITCHBAR_ALLOW_ADHOC=1 make app`, but note the
  Keychain will re-prompt: the private vault is tied to the code signature.

## Principles — please read before proposing changes

1. **Never break the user's Claude Code session.** The active account's
   credentials belong to Claude Code; SwitchBar must never rotate them.
   Only inactive profiles may be refreshed.
2. **Fail safely.** The endpoints SwitchBar consumes are not a public
   stable API. Any change must keep the app harmless when Anthropic
   changes something: keep last data, mark accounts as needing login,
   never corrupt `~/.claude.json` or the Keychain.
3. **No new network destinations.** Requests go to `api.anthropic.com`,
   `console.anthropic.com` and `status.claude.com` only. Anything else
   (telemetry included) will not be merged.
4. **Keychain discipline.** All Keychain access goes through the existing
   `/usr/bin/security` wrapper, without widening ACLs.

## Pull requests

- Add or update tests for what you change; `make test` must pass.
- User-facing strings live in `Sources/SwitchBarCore/Resources/*.lproj` —
  update every language (a test enforces catalog completeness). Machine
  translation is acceptable for the non-Spanish/English catalogs.
- Existing code comments are written in Spanish; keep new comments in
  Spanish or English, but always explain *why*, not *what*.
- Keep commits focused; describe behavior changes in the message body.

## Reporting bugs

Use the issue template. Always include the macOS version, whether the
account is Pro or Max, and what Claude Code version is installed. Never
paste tokens, Keychain dumps, or the contents of `~/.claude.json`.
