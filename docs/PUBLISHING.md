# Publishing the source repository

Use `main` for the source repository. Creating the GitHub repository, committing,
and pushing are separate steps that require explicit authorization. Inspect the
current Git history and remote configuration before publishing.

## Review the source

```sh
python3 scripts/check-public-repo.py
git status --short --untracked-files=all
bash scripts/test.sh
```

Review the actual files before the first commit. `.gitignore` keeps local plans,
progress notes, raw QA reports/screenshots, downloaded dependencies, generated
codec executables, build outputs, and signing material outside Git. Those files
remain on disk. Publish through Git; uploading an archive of the entire working
directory would include ignored material.

The publication check scans tracked and unignored files for configured credential
patterns, personal paths, signing IDs, generated files, and compiled executables.
It prints file locations and categories without printing matched values. It does
not scan Git history or guarantee that every possible secret or personal detail
has been detected. Before later publications, review new commits and any image
metadata as well.

## Verify a clean source build

Install the tools listed in [README.md](../README.md), including both Rust targets,
then run:

```sh
python3 scripts/verify-clean-build.py
```

The command copies only tracked and unignored files into a new directory under
`.build/clean-source.*/source`. It creates empty local Git metadata for the
publication scanner; it does not stage files, create commits, or contact a Git
remote. This works before the first commit, when a real `git clone` would be empty.

The snapshot starts without `vendor/`, bundled codec executables, `node_modules/`,
or DerivedData. It downloads and builds all codecs, builds Universal 2 Release,
checks launch, runs the host-architecture tests, and checks that generated public
source files retain the same Git content and executable permissions. Line-ending
normalization follows `.gitattributes`. System tools and package-manager download caches
may be reused. This checks source completeness on the current Mac; it does not
simulate a fresh macOS installation or exercise the other CPU architecture.

Logs, the input SHA-256 manifest, and `verification.json` stay in the ignored
`.build/clean-source.*` directory. A successful report has `passed: true`. Failed
checks retain their logs. Delete that specific verification directory when its
build products are no longer needed; do not publish its raw reports.

After the first commit and remote exist, repeat the same build and test commands
from a real clone. The workflow in `.github/workflows/ci.yml` performs a fresh
checkout on macOS 15 Apple Silicon and Intel, with Xcode 26.3 and Node.js 24.
No compiled dependency cache or release signing credentials are used by CI.

## Licensing and GitHub setup

- Keep the root MIT license and all notices listed in [LICENSES.md](../LICENSES.md).
- Keep the Nucleo artwork notice and usage restrictions; the app icon is a separate license exception.
- Keep Gifsicle's original source archive, license, and build recipe with its distributions.
- Enable private vulnerability reporting on GitHub and confirm the route described in [SECURITY.md](../SECURITY.md).
- Review the staged diff and files before committing or pushing. Connect only the intended repository remote.
- Check the commit author name and email before the first commit; choose an identity and email address you intend to make public.

## GitHub launch checklist

These steps require the actual repository and remain separate from local preparation:

- Create the intended GitHub repository and confirm its owner, URL, and visibility.
- Enable **Private vulnerability reporting** under the repository's security
  settings, following [GitHub's instructions](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository).
- Open **Security → Advisories → Report a vulnerability** and verify that the
  private form is available. Do not send a test vulnerability report.
- Confirm that [SECURITY.md](../SECURITY.md) is displayed and its reporting route
  matches the enabled feature.
- Verify the intended Git author identity locally with `git var GIT_AUTHOR_IDENT`.
  Do not copy its output into public QA logs.
- Review the files that would enter the first commit with
  `git status --short --untracked-files=all`. Before an authorized commit, review
  the staged diff with `git diff --cached` and `git diff --cached --check`.
- After an authorized push, confirm both macOS CI jobs pass before announcing the
  repository. The local verification does not establish that hosted CI has run.

Release binaries require their own review and signing/notarization checks; see
[DISTRIBUTION.md](DISTRIBUTION.md). Signed Apple distribution artifacts expose the
signer's certificate identity by design, even when source files contain no signing
credentials. Do not upload the existing local reports or build directories.
