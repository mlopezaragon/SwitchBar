# Changelog

## 1.0.1 — 2026-09-05

- Account enrollment now shares concurrent submissions and retains a successful
  authorization exchange in memory when loading the account profile fails.
  Retrying no longer reuses a consumed authorization code.
- Newly linked or reconnected accounts receive a prioritized usage refresh;
  server-requested usage cooldowns remain respected.
- Unchanged account synchronization avoids rewriting the credential vault.
  Older credentials and in-flight renewals cannot overwrite a newer login.
- Selecting the already-active account no longer restores a stale saved token.
- Active usage checks target 30–60 seconds, with shared request spacing, fair
  standby scheduling, separate usage/renewal backoff and faithful Retry-After.
- Auto-switch displays missing-data and manual-login pauses and verifies a
  destination before changing accounts. Open Claude sessions keep their
  original account; SwitchBar does not restart or migrate running agents.
- Background polling never renews active Claude Code credentials and defers
  inactive-token renewal while a running client may still use it.
- Update checks default to once an hour, preserving existing user preferences.
- Validated with 111 automated tests, including concurrent enrollment, retry
  recovery, synchronization races, request pacing and account switching.

## 1.0.0-beta.9 — 2026-07-31

Anthropic rate-limits its OAuth endpoints hard, without documenting the
limits and without sending `Retry-After`, and retrying makes it worse:
there are reports of accounts blocked for days after as few as six token
renewals a day. This release stops SwitchBar from ever provoking that, and
makes sure a renewal problem never costs you the usage numbers themselves.

- Fixed: a rate-limited session renewal also blocked reading that account's
  usage, for up to an hour. They are separate quotas and are now tracked
  separately — as long as the access token works, the numbers keep coming.
  Cooldowns saved by earlier versions are capped on load, so an install
  upgrading from beta.8 recovers on its own.
- Renewals are now almost never needed: while an account is the active one,
  SwitchBar adopts the session Claude Code just renewed, straight from its
  keychain and without spending a single request. Every account therefore
  keeps a token that is hours fresher than before.
- Circuit breaker: after three consecutive refusals, renewals stop being
  attempted for half a day. Insisting does not unblock anything and does
  prolong the punishment.
- Accounts that are not in use are polled every fifteen minutes instead of
  every three. Their usage only moves if someone else is using them.
- API errors now say what actually happened — rate limit, expired code,
  server error with its code — instead of a single "could not complete the
  operation" for every failure.
- An account whose session cannot be renewed says so in its card and
  explains the way out that does work: `claude logout` and `claude login`
  in a terminal. Reconnecting from within the app cannot help, because it
  goes through the very endpoint that is blocked.

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
