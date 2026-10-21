# Contributing to Resim

Use English for code comments, interface text, documentation, issues, and pull requests.
See [README.md](README.md) for the macOS toolchain and build instructions.

## Development

1. Build the app with `bash scripts/build.sh` and run `bash scripts/test.sh`.
2. Keep changes focused. Preserve original files, validate image candidates, and clean up temporary files on failure or cancellation.
3. Add regression coverage when changing image handling or file safety. Use generated or redistributable fixtures; document their origin in [ResimTests/Fixtures](ResimTests/Fixtures/README.md).
4. Regenerate the project after adding source files with `python3 scripts/generate-project.py`. Update English strings with `python3 scripts/update-strings.py`.
5. Describe the change, relevant limitations, and checks performed in your pull request. See [docs/QA.md](docs/QA.md) for manual checks.

## Before sharing changes

Run `python3 scripts/check-public-repo.py` and `git diff --check`.
Review `git status --short --untracked-files=all` and the actual diff before committing.
The publication check inspects both tracked files and unignored new files; it is a local safeguard, not an exhaustive security audit.

Before changing build tooling or preparing the first publication, run
`python3 scripts/verify-clean-build.py` to rebuild and test a source-only snapshot.
It does not create commits. See [docs/PUBLISHING.md](docs/PUBLISHING.md) for its
scope and local log locations. GitHub Actions runs Release builds and tests on
macOS Apple Silicon and Intel without a compiled dependency cache.

Keep signing certificates, credentials, personal images, build products, machine reports,
and private development notes out of Git. Share sanitized logs and synthetic examples.
Preserve third-party attribution and license notices. Never commit or upload signing secrets.

Contributions to original Resim code are provided under the [MIT license](LICENSE).
Third-party components retain their own licenses; see [ThirdPartyNotices.md](Resim/Resources/Licenses/ThirdPartyNotices.md).
