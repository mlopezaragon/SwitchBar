# Changelog

## 1.0.0-beta.8 — 2026-07-31

Accounts that had not been active for a while could go half a day without
their usage being checked, while the panel kept showing their last known
numbers as if they were current. This release fixes the cause and makes the
app honest about what it does and does not know.

- Fixed: an inactive account whose session had expired was asking Anthropic
  to renew it every ten minutes. The server answers "too many requests"
  without saying how long to wait, so the app kept retrying and kept the
  account rate-limited — dozens of renewals per hour, indefinitely. A
  renewal is now attempted at most every thirty minutes, doubling up to an
  hour after repeated refusals.
- Fixed: the auto-switch notification claimed all accounts were near their
  limits when the real reason was that their usage could not be checked.
  Both situations now have their own message, and neither repeats more than
  once every thirty minutes.
- Before giving up, auto-switch now queries the accounts it has no fresh
  data for, instead of silently ruling them out and staying put.
- Accounts with stale data are dimmed in the panel and show when they were
  last checked, so an old 0% is never mistaken for free capacity.
- An account resting with no open session is no longer discarded as a
  switch target: no 5-hour window means zero usage, not unknown usage.
- Fixed: macOS could freeze the polling loop. As a menu bar app with no
  windows, SwitchBar was a prime candidate for App Nap; it now declares its
  activity while still allowing the Mac itself to sleep.
- Usage requests now time out after twenty seconds. A stuck request used to
  hold up every other account's turn for a full minute.
- Idle accounts yield their turn while their data is still valid, so
  requests go where they matter, and a turn lost to a simultaneous request
  is retried on the next round instead of skipped entirely.
- Unexpected HTTP codes are no longer reported as connection failures, and
  every usage check is now traceable:
  `log stream --predicate 'subsystem == "com.mlopara.ClaudeSwitch"'`.
- Add an account without touching the terminal: the browser authorization
  flow now runs inside the app.
- Fixed: card outlines and the pinned position broke when switching
  language.

## 1.0.0-beta.5 — 2026-07-30

- Minimum macOS lowered from 26 (Tahoe) to 14 (Sonoma). The app used no
  Tahoe-only API; three more years of Macs can now run it.

## 1.0.0-beta.4 — 2026-07-30

- Notarized by Apple: the app now opens without any Gatekeeper prompt.
- Automatic updates via Sparkle 2: SwitchBar checks a signed appcast and
  offers new versions in place; a "Check for updates" button and the
  installed version appear in the settings panel.

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
