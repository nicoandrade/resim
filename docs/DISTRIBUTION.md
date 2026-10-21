# Distribution

`scripts/package.sh` creates a Universal 2 app, a compressed DMG with an Applications shortcut and a themed drag-to-install window, and SHA-256 files. Its output is `dist/Resim.app`, `dist/Resim-VERSION.dmg`, and `dist/Resim-VERSION.dmg.sha256`, using the app's version. After signing, stapling, and any required verification finish, it also prepares an identical `dist/Resim.dmg` and its `dist/Resim.dmg.sha256` for GitHub Releases.

The installer shows Resim and Applications over a subtle version of the landing's
sunset landscape, with directional chevrons. `README.txt` remains included but
hidden to keep the install window simple. Background resources are in
`resources/dmg/`; the Retina background is generated locally using AppKit.
`scripts/create-dmg.sh` installs the pinned `dmgbuild` tooling into an ignored
`.build/dmg-tools` virtual environment on first use (network access required).
It writes Finder settings directly, without GUI scripting or Automation access.
Each package mounts the completed image read-only and checks the saved layout,
background, hidden instructions, Applications link, and mounted app signature.

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
redeploy or per-visitor API request is needed for later app releases. Use the local
command below to build and publish automatically. Creating a release manually
does not build its assets; upload verified files before publishing it.
Local ad hoc packages remain outside the public-release requirements above,
even though they also receive the stable filenames.

## Automated local releases

Run everything on the Mac that already has your Developer ID Application
certificate and `notarytool` profile. GitHub hosts the finished files; no Apple
certificate, private key, password, or signing secret is uploaded to GitHub.
GitHub Actions continues to build and test source on Apple Silicon and Intel.
It does not sign or publish releases, and pushing a tag alone does not publish.

### Local setup

Install the build tools in [README.md](../README.md) and authenticate GitHub CLI
with `gh auth login`. Use the local Keychain setup above for Apple credentials;
no password needs to be read, copied or exported by the release command.

Select your existing notarization profile with `NOTARY_PROFILE` or
`--notary-profile`. To remember its name on this Mac, create the ignored file
`local/release.json` (the name below is an example):

```json
{"notary_profile": "resim-release"}
```

This file contains a profile name, not Apple credentials. Keep it local.
The command selects the only valid Developer ID Application identity in the
Keychain. If several are installed, set `SIGN_IDENTITY` to the SHA-1 identifier
shown by `security find-identity -v -p codesigning`; no private key is exported.

Check the setup without building or publishing:

```sh
python3 scripts/release.py --check
```

### Publish the next version

1. Update `MARKETING_VERSION` and the build number in `scripts/generate-project.py`,
   run the generator, and add the matching dated section to `CHANGELOG.md`.
2. Commit and push the reviewed source to `main`.
3. On the signing Mac, run:

   ```sh
   python3 scripts/release.py --publish
   ```

The command requires a clean `main` matching `origin/main`, validates the version
and release notes, checks GitHub authentication and the local signing profile,
and creates an isolated clone under `.build/local-release.*/source`. This starts
without compiled codec outputs or DerivedData; download caches can be reused.
Source edits made during the build cannot change that snapshot.

It builds Universal 2, checks launch, runs the host-architecture tests and source
publication checks, and requires generated source to retain its Git content and
executable permissions (including `.gitattributes` line-ending normalization). It signs
and notarizes the app and DMG using `scripts/package.sh`, staples both tickets,
and requires strict signature, architecture, Gatekeeper, and checksum verification.

Before uploading, it waits for successful **macOS checks** on both GitHub runner
architectures for the exact source commit. It then creates the matching version
tag (or resumes an identical existing tag), creates a draft release, and uploads
`Resim.dmg` and `Resim.dmg.sha256`. It compares GitHub's uploaded SHA-256 digests
and sizes before publishing and marking the release Latest. Finally it downloads
both fixed landing URLs anonymously and compares the files with the local package.
No landing edit or Vercel deployment is needed.

The script does not bump the app version, commit or push source changes for you.
A version that is already published, is older than Latest, or has a tag pointing
to another commit is rejected. Tags and published assets are never overwritten.
Concurrent local runs in the same checkout are blocked.

Failures before publication leave the previous Latest release in place. A failed
upload may leave a tag and draft for the verified commit; rerun from the same
source to resume. If the anonymous download check fails after publication, inspect
the public assets before corrective action. Existing public releases remain immutable
to the local command; do not try to overwrite an existing version by rerunning it.

### Rehearse without publishing

```sh
python3 scripts/release.py
```

This performs the clean build, host tests, signing, Apple notarization, stapling,
and full package verification. It can reuse an already published app version and
creates no GitHub tag, release or asset. It does submit the app and DMG to Apple's
notarization service through the existing local profile.

Each run prints its workspace and artifact locations. Build logs, signing logs,
notarization receipts, verification reports and final packages stay in the ignored
`.build/local-release.*` directory. `.build/last-local-release.json` points to the
last successful run. These local reports can contain signing metadata and machine
paths; do not attach them to a public release or commit them.

The Developer ID certificate and credentials remain in the local Keychain; they
still need to be renewed locally when they expire. Release publication requires
this Mac to run the command with network access to GitHub and Apple. The command
does not provide unattended cloud builds or automatic updates inside the app.

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
