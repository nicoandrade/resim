# Agent instructions

Respond briefly and directly. Expand only when requested or necessary.

## Publishing releases

When the user asks to publish a new release, use the local workflow in
[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md#automated-local-releases) automatically:

1. Use the `keep-a-changelog` skill to prepare the intended version and dated
   changelog entry. Reuse an already prepared version. Update the authoritative
   version and build number in `scripts/generate-project.py` and regenerate the
   Xcode project.
2. Review the release changes, preserve unrelated work, and commit and push the
   release source to `main`. The publishing script requires a clean checkout
   matching `origin/main`. Never force-push or overwrite a published tag.
3. On the signing Mac, run `python3 scripts/release.py --publish`. Use the existing
   local Keychain identity and notarization profile; keep machine configuration
   in the ignored `local/release.json`. Do not export Apple credentials or set up
   GitHub signing Secrets for this workflow.
4. Let the script perform the clean build, tests, signing, notarization, stapling,
   package and checksum verification, CI checks, tag creation, draft upload,
   publication as Latest, and anonymous download verification. Report the release
   URL and verification result. Keep `Resim.dmg` and `Resim.dmg.sha256` filenames
   stable so the landing download remains current without a landing deployment.

An explicit publication request authorizes these release steps; do not ask for
separate confirmation of the method or publication. Honor narrower instructions:
preparation-only requests must not publish, and explicit restrictions on commits
or pushes take precedence. Use `python3 scripts/release.py --check` for preflight
only and `python3 scripts/release.py` for a signed rehearsal without publication.
Do not bypass failed checks or upload ad hoc packages, credentials, or raw local
release reports.
