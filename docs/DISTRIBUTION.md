# Distribution

`scripts/package.sh` creates a Universal 2 app, a compressed DMG with an Applications shortcut and `README.txt`, and a SHA-256 file. Its output is `dist/Resim.app`, `dist/Resim-VERSION.dmg`, and `dist/Resim-VERSION.dmg.sha256`, using the app's version.

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
