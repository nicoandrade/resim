---
name: keep-a-changelog
description: Choose or reuse the appropriate project version, synchronize its authoritative version files, and maintain CHANGELOG.md or CHANGELOG.txt using Keep a Changelog and Semantic Versioning. Use when preparing a release, bumping a version, writing release notes, or updating a changelog, including requests such as "aumentar versión" or "actualizar el changelog". Works across web, mobile, libraries, and other project types.
license: MIT
---

# Keep a Changelog

Prepare a coherent local release: a justified version, synchronized version sources, and human-readable release notes. Follow [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## Establish the release scope

- Read the project's release instructions, version sources, package manager configuration, and existing changelog. Use the existing `CHANGELOG.md` or `CHANGELOG.txt`; create `CHANGELOG.md` if neither exists. If both exist, find the maintained source before editing either.
- Inspect `git status --short`, staged and unstaged diffs, and relevant untracked files. Include committed changes since the last release: identify its tag or release commit using the changelog and version history, then inspect that range through the working tree. A clean working tree does not imply there are no unreleased changes. Do not assume the nearest tag belongs to the package being released.
- Read the affected behavior and public contracts; commit titles alone do not establish compatibility. Public contracts include APIs, CLI options, configuration, supported runtimes, data formats, and documented application workflows.
- Respect a user-selected scope or version. In a monorepo, identify the affected package and whether releases are independent or synchronized. Preserve unrelated work.
- If release history is unavailable, use the current diff and existing `Unreleased` notes and report that limit. Ask only if missing scope or compatibility information would materially change the version or make the notes misleading.

## Reuse a prepared version or bump

Compare the authoritative current version with the last released version using the changelog, relevant tags, and version-file history together. Inspect committed version edits as well as the working tree. A missing changelog entry alone does not prove a version is unreleased.

- **Already increased:** if the user or release tooling advanced the version for this unreleased work, keep that target and write or complete its changelog entry. For example, last release `1.3.0` and a prepared `1.4.0` means document `1.4.0`, not bump it again. Synchronize any stale dependent version files.
- **Not yet increased:** if the current version is still the last released version and there are new in-scope changes, choose the bump below, update the version sources, and add the release entry.
- **Already prepared:** if both version and notes cover this release, only fill genuine gaps; repeating the request should not create another bump or duplicate heading. Do not replace an already published version with different contents.
- **Uncertain:** if history is missing or conflicting, do not assume the configured version is either old or new. Ask which version is the intended release when that distinction determines whether to bump.

For notes-only requests, leave the version unchanged. Use `Unreleased` unless the user requests a specific release entry or a clearly prepared version identifies the intended release. With no unreleased changes or explicit empty-release request, avoid creating an empty release.

## Choose the version

Use the highest applicable impact across the release, rather than the size of the diff:

| Impact | Bump | Example from 2.4.7 |
| --- | --- | --- |
| Incompatible public contract, removal, or migration that breaks compatibility | Major | 3.0.0 |
| Backward-compatible public feature or public API deprecation | Minor | 2.5.0 |
| Backward-compatible fix, security correction, or maintenance release | Patch | 2.4.8 |

- A large refactor can be patch; a one-line contract change can be major. Dependency upgrades take the impact of their resulting behavior, not the dependency's own version number. A security change can still require minor or major when it changes a public contract.
- Respect an exact target or bump requested by the user. If it conflicts with the observed impact, explain the mismatch; do not silently substitute a different target or hide the breaking change.
- For `0.y.z`, follow the project's documented policy. Without one, use patch for compatible fixes and minor for features or breaking changes, explicitly documenting breakage. Reserve `1.0.0` for an intended stable release.
- Follow the existing prerelease channel and tooling; distinguish advancing a prerelease from promoting it to stable. Do not silently discard prerelease identifiers. Build metadata alone does not increase SemVer precedence.
- For a new unversioned project, use its release policy or an explicit target; otherwise start at `0.1.0`. Do not replace a deliberate non-SemVer scheme without user direction.

## Synchronize version sources

Trace the release/build configuration to its authoritative version source before editing. File names are clues, not authority: an app may have `package.json` only for tooling, and version values may be inherited, computed, or supplied by CI. Edit the owning source with the project's existing tooling or a structured edit; do not add competing sources or edit generated artifacts.

| Project | Where to look first |
| --- | --- |
| Node.js / JavaScript / TypeScript package or web app | The released package's `package.json` → `version`, unless release tooling derives it elsewhere. |
| Expo app | Effective `version` in `app.json` (`expo.version`) or `app.config.js` / `app.config.ts`; follow imports if it derives from `package.json`. Check platform overrides, maintained native projects, and `eas.json`. |
| Native Android / React Native Android | App-module Gradle configuration (`build.gradle` / `build.gradle.kts`) → `versionName`, or its shared property/plugin source; account for flavors. |
| Native iOS / React Native iOS | `MARKETING_VERSION` in Xcode build settings / `.xcconfig`, or the source of `CFBundleShortVersionString` in `Info.plist`. |
| Flutter | `pubspec.yaml` → `version: X.Y.Z+N`; inspect build/CI overrides. |
| Rust / Python / other stacks | `Cargo.toml`, `pyproject.toml`, the project's manifest or `VERSION`; follow workspace inheritance or dynamic version providers. |

- When `package.json` owns or intentionally mirrors the release version, update it and its root metadata in `package-lock.json` or `npm-shrinkwrap.json` when present. Otherwise leave its tooling/package version alone. Inspect Bun, pnpm, and Yarn lock formats before changing them; many do not store the root version. Do not replace dependency versions that happen to match the old project version.
- Mobile: distinguish the public release version from build identifiers (`android.versionCode`, `ios.buildNumber`, `CURRENT_PROJECT_VERSION` / `CFBundleVersion`, Flutter's `+N`). Follow the existing build policy; do not apply SemVer to these counters or double-increment values managed by CI/EAS. [Expo's versioning guide](https://docs.expo.dev/build-reference/app-versions/) explains local versus remote EAS versions. Do not change `runtimeVersion` or regenerate native projects just to update the changelog; inspect those policies when preparing an actual app release.
- In workspaces, update internal dependency ranges only where required by the repository's release policy. Do not bump every package by default.
- Avoid commands that implicitly commit, tag, publish, deploy, or run unreviewed release hooks. Preparing release files does not authorize those actions. Avoid unrelated dependency resolution or lockfile churn.

## Write the changelog

- Language priority: an explicit user preference first, otherwise the language of existing change descriptions, otherwise English. Keep established category translations; do not translate historical entries. Respond to the user in their language, independently of the changelog's default language.
- Preserve the file's extension, relevant introduction, and historical entries. Apply the convention to new entries without rewriting all past releases. For `.txt`, retain plain-text headings while keeping the same dates, ordering, and categories.
- Keep an `Unreleased` section first, followed by releases newest first. For Markdown, prefer `## [Unreleased]` and `## [X.Y.Z] - YYYY-MM-DD`, but preserve heading syntax required by existing release validators (for example, unbracketed versions), adding comparison links separately when necessary. Use the user's release date or today's local date; describe a prepared release as local preparation, not proof of publication.
- For a new file, start with `# Changelog`, a short purpose statement, and links identifying Keep a Changelog 1.1.0 and Semantic Versioning if the project follows it.
- Group notable changes under the following categories, using established translations when the changelog is localized. Include only categories that have entries:

| Category   | Contents                       |
| ---------- | ------------------------------ |
| Added      | New features                   |
| Changed    | Changes to existing behavior   |
| Deprecated | Features scheduled for removal |
| Removed    | Removed functionality          |
| Fixed      | Bug fixes                      |
| Security   | Vulnerability fixes            |

- On release preparation, move only the in-scope `Unreleased` items into the version entry and retain future work under `Unreleased`. Preserve useful existing notes, remove duplicates, and add missing notable changes supported by the code. An empty `Unreleased` heading is fine; empty category headings are unnecessary.
- Describe the observable result and why users care. Combine related commits into one clear entry; omit formatting noise and raw commit lists. Make deprecations, removals, breaking behavior, and necessary migration steps explicit within the applicable categories.
- Add or update release and comparison links when the repository URL, hosting conventions, and tag pattern are known. Point `Unreleased` from the new version tag to `HEAD`, and each version from its predecessor to that version's tag. For a first release, link to its release/tag. Follow the actual tag naming scheme; do not invent URLs. If no reliable URL is available, use plain version headings without unresolved link references.
- Preserve withdrawn releases and their `[YANKED]` marker. Do not invent past releases, dates, security claims, issue IDs, or completed verification.

## Verify and report

Review the final diff and status. Check that the intended manifests and lock metadata agree, each version appears once, dates and ordering are correct, comparison references resolve, and unrelated history and changes are preserved. Run the repository's required checks and any release consistency check; a metadata-only update does not automatically require every application test.

Report the old and new version, the reason for the bump, files changed, and verification performed or omitted. For changelog-only work, state that the version was unchanged. Do not commit, tag, push, publish, or deploy unless the user authorized it.
