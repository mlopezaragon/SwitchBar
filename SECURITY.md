# Security policy

SwitchBar handles OAuth session tokens for your Claude accounts, so
security reports are taken seriously.

## Reporting a vulnerability

Please do **not** open a public issue for security problems. Use GitHub's
private vulnerability reporting ("Report a vulnerability" under the
Security tab of the repository). You will get an acknowledgement within a
few days.

When reporting, never include real tokens or Keychain contents. If a proof
of concept needs credentials, describe the steps instead of pasting values.

## Scope

Reports of particular interest:

- Any way to read the private profile vault without the app's signature.
- Any path that widens Keychain ACLs or leaves secrets on disk.
- Corruption of the user's Claude Code session (`~/.claude.json` or the
  official Keychain entry).
- Requests to destinations other than the three documented ones.

## Supported versions

Only the latest release receives fixes.
