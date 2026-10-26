# Changelog

## 1.4.1 — 2026-10-26

- Automatic switches no longer wait for the destination's turn in the
  polling rotation. SwitchBar re-reads the destination before switching,
  but the poller had just used the request slot (requests are 30 seconds
  apart), so that read was dropped and the switch was put off until the
  destination's next scheduled read: minutes with nine accounts, enough for
  a Team window to go from the threshold to 100 %. Every automatic switch in
  the log happened in the same second the destination was polled. It now
  waits for the slot, at most 30 seconds.
- The usage pace is measured after two minutes when at least 10 points were
  spent, instead of always waiting eight: a Team window used by several
  sessions is gone in about ten minutes.
- The first reading of a freshly opened 5-hour window counts toward the
  pace. The server rounds its reset time down to ten minutes, which placed
  the window's opening before the previous reading, and the reading was
  discarded.
- Destinations are ranked by how long they would stay active before the
  threshold or the pace switch moves on, not by how long they would take to
  reach 100 %. Only a destination it would leave within 5 minutes is a last
  resort; a short-lived one keeps its group, so under heavy load a fresh
  Team still goes before a Max. Autonomous mode moves to accounts that stay
  active for at least 8 minutes.

## 1.4.0 — 2026-10-26

- Accounts with no visible weekly limit (Team, which only reports Fable)
  are spent before accounts with a weekly limit (Max). Their 5-hour window
  refills five hours after it opens without costing any weekly quota, so
  Max weeks are kept for when Team windows run out. Team accounts no longer
  compete through their Fable reset, which says nothing about what limits
  them.
- A week is still never wasted: when, at the measured pace and assuming you
  work half the remaining time, an account could not spend what is left of
  its week before the reset, that week goes first. Each 5-hour window caps
  how fast a week can be spent, so working faster does not change this.
  Without a measured weekly cost, only the last day before a reset counts.
- Order when switching: quota that would be lost (an open Team window with
  room, or a week at risk), then Team accounts with their window unopened,
  then the rest of the weekly accounts by weekly reset. Autonomous mode
  moves early whenever another account with at least 15 points of room
  comes earlier in that order, or within the same group expires at least
  30 minutes sooner.
- When the active account has to switch and no account has room left,
  SwitchBar leaves active the account that recovers first (the 5-hour window
  that resets soonest), at least 15 minutes earlier than the current one.
  Claude Code moves to the active account when its own runs out and waits
  there, so it resumes as soon as possible. Only accounts blocked by their
  5-hour window qualify, never one with a personal cap or one you left by
  hand, so no week or shared quota is spent waiting.
- With "Use your usage pace", a destination is a last resort under 30
  minutes instead of 45, and autonomous mode moves to accounts that last at
  least 30 minutes instead of an hour: a whole Team window lasts a little
  over an hour, and stricter limits left half-spent windows unused.
- An account you leave by hand with no visible weekly limit (Team) now goes
  to the back of the line only until its open 5-hour window resets, instead
  of until its Fable reset days later: its window is the only limit it
  shows. Marks saved by earlier versions stop counting as soon as that
  account has no open window, so Team accounts left by hand days ago are
  used again.
- New notifications explain each autonomous move (Team window, expiring
  window, week at risk) and the wait on the first account to recover.

## 1.3.0 — 2026-10-24

- Each account's card shows the limit resets Anthropic has granted it, for
  example "Limit resets: 1 of 2 · use it by Oct 30". The detail window
  lists each batch with what it resets (5-hour window, week, or both), its
  deadline, and whether it can be used now or only at a limit. An account
  without any says so there, with the reason Anthropic gives (plan, seat
  type, none granted…).
- The data comes from the `cedar_ember` block of the usage endpoint, the
  one Claude Code's `/limit-reset` command reads. It is requested in the
  same call SwitchBar already makes, so there are no extra requests.
  Anthropic does not document it: when the block is missing or malformed
  the card shows nothing and usage is unaffected.
- Today Anthropic only reveals resets to Claude Code and claude.ai: asked
  by any other app, every account comes back ineligible with reason
  `surface`. SwitchBar does not pose as Claude Code to get them, so the
  detail window says they cannot be seen from SwitchBar, and they appear
  on their own if Anthropic opens the data to other apps.
- Automatic switching spends first whatever would expire first, including
  5-hour windows: an already open window with room left goes before opening
  a fresh one, because what it does not use before its reset is lost. Until
  now only weekly resets counted, and a fresh account always won the
  tie-break, leaving open windows to expire half used.
- New "Use your usage pace" setting, on by default. SwitchBar keeps a week of
  usage readings per account (`usage-history.json`, mode 0600, percentages
  and reset times only) and measures how fast each one is spent:
  - It switches before the threshold when, at the current pace, the active
    account would run out of its 5-hour window within 20 minutes, so a new
    session does not start on an account about to cut off. It never switches
    later than the threshold, since open sessions stay on their account and
    drain it anyway.
  - Destinations that would last under 45 minutes are a last resort; among
    the rest, the one that lasts longest wins ties. Autonomous mode only
    moves early to an account that would last at least an hour.
  - The panel forecasts how long quota lasts across all accounts at the
    current (or usual) pace, and a notification warns 45 minutes before
    every account would hit its limit.
  - The detail window shows each plan's measured pace and how much longer
    one plan lasts than another for the same work.
- The menu bar panel shrinks back when a notice or error goes away. Its
  window grew to fit them but never shrank again, so the panel sat
  centered in a taller window with empty strips above and below.
- Validated with 189 automated tests.

## 1.2.0 — 2026-10-23

- Weekly resets are compared exactly. 1.1.0 treated resets less than 6
  hours apart as a tie, so an account resetting in 3 hours could lose to
  one resetting in 4. Now the earlier one always wins; the 5-hour usage
  only breaks exact ties.
- Autonomous mode replaces "Use expiring weekly quota early" (same setting,
  still on by default). SwitchBar keeps the account whose week resets first
  active: it moves to another account without waiting for a limit whenever
  that account resets at least 30 minutes earlier and has at least 15 points
  of room on every reported window. The 24-hour horizon and the 10-point
  weekly minimum are gone.
- Team accounts take part in autonomous mode, using their Fable reset as
  the weekly one. Their general week is still not reported, so only the
  reported windows are checked.
- An account the user leaves by hand (click, undo or `/login`) goes to the
  back of the line until its weekly reset, at most 7 days, and autonomous
  mode does not move back to it on its own. The user may know something
  the app cannot see, such as a Team seat at its weekly limit.
- Validated with 147 automated tests.

## 1.1.0 — 2026-10-23

- Automatic switching picks the destination by when its weekly quota
  expires. Quota left unused at a weekly reset is lost, so the account whose
  week resets first goes first and accounts that reset later keep theirs for
  afterwards. Resets less than 6 hours apart count as the same, and the
  5-hour usage decides between them. Team accounts, whose general week is not
  reported, use their Fable reset, which shares the weekly cycle.
- Accounts with less than 5 points before a threshold are only a last
  resort: switching to them meant switching again minutes later.
- New "Use expiring weekly quota early" setting, on by default. When another
  account's week resets in less than 24 hours with at least 10 points of
  room, and the active account resets at least 6 hours later, SwitchBar
  moves to it without waiting for a limit. An account picked by hand (click,
  undo or `/login`) is kept until it reaches a limit, and after any automatic
  switch it waits 10 minutes before moving early again.
- Limits are never relaxed: an account at any threshold or at its personal
  cap is never a destination, however soon its quota expires.
- The destination is no longer whichever account was polled in the last
  minute; every candidate is ranked, then the chosen one is verified.
- The panel and the detail window mark the account automatic switching
  would move to next.
- Validated with 144 automated tests.

## 1.0.5 — 2026-10-23

- Adding an account can request a specific organization. With the same
  email in a personal Max and a Team, the login page kept authorizing the
  Max organization, even after switching organization on claude.ai. The
  "Organization" picker lists the Team organizations already known from
  other saved accounts and asks Anthropic for that one. If a different
  organization is authorized, nothing is saved and the sheet says which.
- Validated with 128 automated tests.

## 1.0.4 — 2026-10-23

- The account list in the menu bar panel scrolls. With six or more
  accounts the panel grew past the bottom of the screen, hiding the last
  cards and the "Add account" button, as if there were an account limit.
  There is none.
- New Sparkle update signing key. The previous EdDSA private key was lost
  with the Mac that held it; 1.0.1–1.0.3 accept this update through
  Sparkle's key rotation, because it carries the same Developer ID code
  signature, and later updates are signed with the new key.
- Validated with 128 automated tests.

## 1.0.3 — 2026-10-23

- Fixed: Team accounts showed "No limit" for the week. Team seats do have
  a weekly limit; Anthropic's usage endpoint just doesn't report it for
  them. The row now reads "Not reported", and its tooltip explains it.
- Usage checks no longer trip Anthropic's rate limit. The endpoint limits
  each account to a small burst refilling at about one request every two
  minutes, and the active account was polled every minute. It is now
  polled every 150 s (60 s only near a threshold with auto-switch on), an
  estimated per-account quota keeps bursts within the server's, and
  standby accounts at 100 % wait for their reset instead of polling.
- "Sign in again" appears only when Anthropic refuses to renew a session.
  Stale data from a usage pause no longer asks for a login it can't fix.
- Fixed: the same email in two organizations (a personal Max and a Team)
  could only be added once; the second login replaced the first. Profiles
  are now kept per account and organization, and existing ones migrate on
  launch. Reconnecting requests the profile's organization, and logging in
  again to an account that is already there says so and explains how to
  pick the other organization on claude.ai.
- Validated with 128 automated tests.

## 1.0.2 — 2026-10-23

- Fixed: inactive accounts stopped renewing their session whenever Claude
  Code (or any node/bun process) was running, so within hours their usage
  froze and the cards asked for a new browser login. They renew again while
  terminals are open: Claude Code re-reads its Keychain entry before every
  refresh, so an older terminal never presents the token SwitchBar rotates.
  Switching accounts waits for an in-flight renewal to finish.
- A rotated refresh token no longer inherits the previous token's expiry,
  which could mark a live session as needing login.
- Cards and the detail window show each account's plan (Pro, Max, Team,
  Enterprise). Team and Enterprise accounts are highlighted, and the tooltip
  names the organization. The plan comes from the account's organization
  type, because Claude Code leaves `subscriptionType` empty for Team.
- Plans without a general weekly limit (Team reports only the 5-hour and
  Fable windows) show "No limit" instead of an empty "—" bar.
- README and PRIVACY name the current token refresh host
  (`platform.claude.com`).
- Validated with 117 automated tests.

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
