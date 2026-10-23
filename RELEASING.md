# Releasing SwitchBar

Checklist for cutting a release. All steps run from the repo root.

1. Update `CHANGELOG.md`, bump `VERSION` in the `Makefile`, and bump
   `CFBundleShortVersionString` / `CFBundleVersion` in `Resources/Info.plist`
   (Sparkle compares `CFBundleVersion`, so it must always increase).
2. `make test`
3. `make dmg` — builds the universal app, signs it (hardened runtime +
   timestamp) and produces `SwitchBar-<version>.dmg` plus its SHA-256.
4. `make notarize` — submits the DMG to Apple and staples the ticket.
   Requires stored credentials:
   `xcrun notarytool store-credentials switchbar-notary --apple-id <id> --team-id 3UJLJZR99P --password <app-password>`.
   The staple changes the file, so use the SHA printed by this step.
5. `gh release create v<version> SwitchBar-<version>.dmg SwitchBar-<version>.dmg.sha256 --title "SwitchBar <version>" --notes "…"`
   (add `--prerelease` for betas).
6. `scripts/make-appcast.sh <version>` — signs the DMG with the Sparkle
   EdDSA key from the Keychain and regenerates `appcast.xml`.
   Commit and push it: the update feed is served from `main`.
7. Update `Casks/switchbar.rb` in the `homebrew-tap` repository with the
   new version and SHA-256, commit and push.

## Invariants

- Never change the code-signing identifier (`com.mlopara.ClaudeSwitch`) or
  the storage identifiers — see CONTRIBUTING.md.
- The Sparkle private key lives in the maintainer's login Keychain, which is
  lost with the Mac. Keep an offline copy: `generate_keys -x <file>` exports
  it (store the file in a password manager, then delete it) and
  `generate_keys -f <file>` imports it on a new Mac.
- If the private key is lost anyway, rotate it (done in 1.0.4): run
  `generate_keys` to create a new one, put its public key in
  `SUPublicEDKey`, and sign the next release with it. Installed versions
  accept that one update because Sparkle 2 allows the EdDSA key to change
  when the new app has the same Apple code signature (same Developer ID
  certificate and identifier). Never change the EdDSA key and the code
  signing certificate in the same release: that breaks the chain of trust
  and users would have to reinstall by hand.

## Homebrew official cask (pending)

Once a stable, notarized release exists, submit `switchbar` to
`homebrew/homebrew-cask` so `brew install --cask switchbar` works without
the tap. Requirements checked: open source, signed and notarized binary,
stable versioning, working `zap` stanza. The tap remains for betas.
