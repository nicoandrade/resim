# Distribution

`scripts/package.sh` creates a Universal 2 app, a compressed DMG with an Applications shortcut and `README.txt`, and SHA-256 files. Its output is `dist/Resim.app`, `dist/Resim-VERSION.dmg`, and `dist/Resim-VERSION.dmg.sha256`, using the app's version. After signing, stapling, and any required verification finish, it also prepares an identical `dist/Resim.dmg` and its `dist/Resim.dmg.sha256` for GitHub Releases.

## Local package

```sh
bash scripts/package.sh
```

Without signing variables, the script uses ad hoc signing. This is a local development artifact, not a notarized public release.

## Signing credentials

For direct public distribution, install a valid Developer ID Application identity and configure a `notarytool` Keychain profile locally. Keep the certificate's private key and credentials outside the repository.

```sh
security find-identity -v -p codesigning
xcrun notarytool store-credentials resim-release --team-id YOUR_TEAM_ID
```

Follow the interactive prompts for the Apple ID and app-specific password. `resim-release` is an example profile name; use your own local profile. Do not put passwords in commands, documentation, environment files, issue reports, or chat. Consult `xcrun notarytool store-credentials --help` for the authentication options supported by your Xcode installation.

## Notarized package

Replace the example identity and profile with your local values:

```sh
SIGN_IDENTITY='Developer ID Application: Example Developer (YOUR_TEAM_ID)' \
NOTARY_PROFILE=resim-release REQUIRE_NOTARIZATION=1 bash scripts/package.sh
```

The script validates access before building, creates a Release app, signs the bundled helpers and app with a timestamp and Hardened Runtime, submits the app to Apple, and staples its ticket. It then creates and signs the DMG, submits it separately, and staples that ticket. Final verification requires valid signatures, Universal 2 architectures, Gatekeeper acceptance, and both stapled tickets.

Submission receipts are stored locally in `.build/notarization.*/`. The verification report and log are written to `.build/package-verification.json` and `.build/package-verification.log`. These files may contain signing identities, submission identifiers, and local paths; do not commit raw reports.

To repeat verification of a Developer ID signed package:

```sh
python3 scripts/verify-package.py --require-notarized
```

The command fails if required checks do not pass. The report's `public_distribution_ready` field must be `true` before publishing the signed artifact. Ad hoc artifacts are outside this verifier's Developer ID requirements.

Publish the verified DMG and checksum together. Do not change or re-sign artifacts after notarization. Keep all bundled third-party notices and the corresponding Gifsicle source/build recipe in the package.

## Stable landing download URL

The landing's download buttons use:

```text
https://github.com/nicoandrade/resim/releases/latest/download/Resim.dmg
```

GitHub redirects this URL to the asset named exactly `Resim.dmg` in the release
marked **Latest**. The filename must remain constant; the release tag and app
version may change. See [GitHub's release-link documentation](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases).

For each public release:

1. Package and verify the signed, notarized app as described above. The stable
   DMG is a byte-for-byte copy of the finalized versioned DMG.
2. Create a draft release for the intended version tag and attach
   `dist/Resim.dmg` and `dist/Resim.dmg.sha256`. Versioned assets are optional.
3. Confirm both assets are present before publishing the stable release and
   marking it Latest. Drafts and prereleases must not replace the public stable
   download. Publishing a new Latest release without `Resim.dmg` breaks the link.
4. Check the fixed URL from a browser without a GitHub login and confirm the
   downloaded checksum matches the finalized package.

The repository and release must be public for anonymous downloads. No landing
redeploy or per-visitor API request is needed for later app releases. Use the tag
workflow below to build and publish automatically. Creating a release manually
does not trigger that workflow; upload verified assets before publishing it.
Local ad hoc packages remain outside the public-release requirements above,
even though they also receive the stable filenames.

## Automated GitHub releases

The [release workflow](../.github/workflows/release.yml) runs when a stable
`vMAJOR.MINOR.PATCH` tag is pushed. It builds Universal 2 from clean checkouts,
smoke-tests and runs the test suite separately on Apple Silicon and Intel, then
signs the tested app in a disposable GitHub-hosted macOS runner. It notarizes and
staples both app and DMG using `scripts/package.sh`, and requires the strict
package verifier to pass. It uploads `Resim.dmg` and `Resim.dmg.sha256` to a
draft, compares GitHub's uploaded SHA-256 digests and sizes, and only then
publishes and marks the release Latest. Finally it downloads both fixed URLs
without authentication and compares them with the verified local assets.

Failures before publication leave the previous Latest release in place. A failed
upload can leave a draft; rerunning the same workflow can resume that draft.
Existing published versions are never overwritten, and a version older than or
equal to Latest cannot replace the landing download. If the final anonymous
download check fails after publication, the workflow reports failure; inspect
the public assets before taking any manual corrective action.

### One-time signing configuration

Create a GitHub environment named `release`, limited to branch `main` (manual
rehearsals) and tags `v*`. Put the following **environment secrets** there,
using [GitHub's environment settings](https://github.com/nicoandrade/resim/settings/environments):

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64 of a password-protected `.p12` containing exactly one valid Developer ID Application certificate **and its private key**. Export only that identity from Keychain Access. |
| `DEVELOPER_ID_P12_PASSWORD` | Password used to protect that export. |
| `NOTARY_APPLE_ID` | Apple account authorized for notarization. |
| `NOTARY_APP_PASSWORD` | An Apple app-specific password, rather than the account password. |
| `NOTARY_TEAM_ID` | The Apple Developer team that issued the signing certificate. |

Load credentials directly into GitHub; never put them in source, command literals,
logs, issues, or chat. For the exported certificate, run `base64 -i /path/to/DeveloperID.p12 | pbcopy`
locally, paste into the GitHub secret field, then clear the clipboard. The remaining
secrets can be entered directly in the settings UI, or using the hidden interactive
prompt from `gh secret set SECRET_NAME --repo nicoandrade/resim --env release`.
The workflow generates its own temporary keychain password. It removes the P12,
deletes the keychain in a `finally` block, and never uploads raw signing logs or
notarization reports as workflow artifacts. It uses no permanent GitHub token:
publication receives the workflow's limited `GITHUB_TOKEN`.

An existing local `notarytool` profile does not automatically become a GitHub
secret. The workflow checks that all five secrets exist before starting a signed
build. Check the certificate's expiry and rotate the certificate or app-specific
password through the same environment when needed.

This follows [GitHub's signing guidance](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
and [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
Keep the standard build/test workflow free of signing credentials. Do not run
secret-bearing release jobs for pull requests or from a self-hosted runner.

### Publish the next version

1. Update `MARKETING_VERSION` and the build number in `scripts/generate-project.py`,
   run the generator, and add the matching dated section to `CHANGELOG.md`.
2. Commit and push the reviewed source to `main`. The tag must identify a commit
   on `main`, and its version must match the authoritative app version and notes.
3. Push the matching tag, for example after preparing version `0.1.1`:

   ```sh
   git tag -a v0.1.1 -m 'Resim 0.1.1'
   git push origin v0.1.1
   ```

The workflow publishes the release; do not create a public release ahead of it.
No change to the landing is needed. Do not move or reuse published tags.

### Rehearse without publishing

Run **Publish signed macOS release** from Actions with branch `main` and mode
`check` to verify clean builds and tests without Apple secrets. Mode `sign` also
checks signing, notarization, stapling, and Gatekeeper using the environment
secrets, but does not create, upload, publish, or modify a GitHub release or tag.
No signed rehearsal binaries or raw reports are retained after the job ends.

```sh
gh workflow run release.yml --repo nicoandrade/resim --ref main -f mode=check
gh workflow run release.yml --repo nicoandrade/resim --ref main -f mode=sign
```

## Rejected or interrupted submissions

Use the submission identifier from the relevant local receipt:

```sh
xcrun notarytool log SUBMISSION_ID --keychain-profile resim-release
xcrun notarytool history --keychain-profile resim-release
```

Inspect Apple's rejection reason, fix the issue, and rebuild. If waiting was interrupted, check the submission history before submitting again.

## Final checks

Download the published DMG through a browser, install it through Finder, and launch it on a separate Mac without existing Gatekeeper exceptions. A normal first-launch confirmation can still appear for a downloaded app.

Exercise both Apple Silicon and Intel hardware and the minimum supported macOS version. Building both architectures does not establish that they have both run successfully. Use the [QA checklist](QA.md) for image processing and cancellation checks.

Keep release documentation generic. Signing identities, Team IDs, Keychain configuration, local machine details, receipts, and private screenshots belong in local release records.
