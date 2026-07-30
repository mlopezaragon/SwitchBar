# Changelog

## 1.0.0-beta.3 — 2026-07-30

- All accounts appear instantly on launch: the last known usage snapshot
  of every account is cached on disk (0600) and restored at startup, with
  expired windows discarded. Fresh data replaces it within seconds.
- First refresh round is accelerated (5-second stride) whenever any
  account has no data or stale data — new installs, newly added accounts,
  and cold starts get fully fresh numbers in about 15 seconds without
  triggering the server's burst penalty.
- Fixed: usage bars were twice as thick on accounts with a personal cap
  configured; the cap tick no longer inflates the bar height.
- Homebrew tap available: `brew install --cask mlopezaragon/tap/switchbar`.

## 1.0.0-beta.2 — 2026-07-30

- Fixed: the app asked for the Keychain password on every usage refresh and
  every account switch. The rename to SwitchBar had changed the
  code-signing identifier, which macOS treats as a different application,
  invalidating the private vault's ACL. The signing identifier is back to
  its historical value and is now documented as immutable.

## 1.0.0-beta.1 — 2026-07-30

First public release, as a beta.

- Menu bar panel with per-account usage bars: 5-hour window, weekly
  window, and the separate Opus/Fable weekly quota, with reset times.
- One-click account switching with undo; capture of the active Claude
  Code session as a profile; guided re-login when a session expires.
- Automatic switching with independent thresholds (5-hour, weekly and
  optional Opus/Fable), notification on switch, and a 15-minute pause
  after a manual `/login` so the user's explicit choice wins.
- Shared accounts: personal caps that rescale usage before the automatic
  policy evaluates it.
- OAuth session renewal for inactive profiles only; the active account's
  credential lifecycle stays owned by Claude Code.
- Rate-limit hygiene: single-account round-robin polling, per-account
  cooldowns honoring Retry-After, and no duplicate fetches within 30
  seconds.
- Anthropic public status surfaced during incidents.
- Localized in 10 languages. Signed, universal (Apple Silicon + Intel)
  build; notarization pending for the stable release.
