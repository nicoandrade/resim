#!/usr/bin/env python3
"""Build, test, sign and notarize locally; publish to GitHub only with --publish."""

import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('github_release', ROOT / 'scripts/github-release.py')
github = importlib.util.module_from_spec(spec)
spec.loader.exec_module(github)


def git(*args, cwd=ROOT):
    return subprocess.check_output(['git', *args], cwd=cwd, text=True).strip()


def validate_checkout():
    allowed = {f'https://github.com/{github.REPOSITORY}', f'git@github.com:{github.REPOSITORY}',
               f'ssh://git@github.com/{github.REPOSITORY}'}
    origin = git('remote', 'get-url', 'origin').rstrip('/').removesuffix('.git')
    github.require(origin in allowed, 'origin must identify the intended GitHub repository.')
    github.require(git('branch', '--show-current') == 'main', 'Run the release from main.')
    github.require(not git('status', '--porcelain'), 'Commit and push source changes before releasing.')
    subprocess.run(['git', 'fetch', '--quiet', 'origin', 'main', '--tags'], cwd=ROOT, check=True)
    sha = git('rev-parse', 'HEAD')
    github.require(sha == git('rev-parse', 'origin/main'), 'Local main and origin/main must match.')
    return sha


def build_environment():
    environment = os.environ.copy()
    # Download caches may be reused; compiled codec and compiler caches may not.
    for key in ('CARGO_TARGET_DIR', 'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER',
                'SIGN_IDENTITY', 'NOTARY_PROFILE', 'NOTARY_KEYCHAIN', 'SKIP_BUILD'):
        environment.pop(key, None)
    environment['CONFIGURATION'] = 'Release'
    if not shutil.which('cmake', path=environment.get('PATH')):
        try:
            import cmake
            environment['PATH'] = cmake.CMAKE_BIN_DIR + os.pathsep + environment.get('PATH', '')
        except ImportError:
            pass
    required = ('git', 'gh', 'xcodebuild', 'xcrun', 'security', 'cmake', 'nasm', 'cargo', 'rustup', 'node', 'npm')
    missing = [name for name in required if not shutil.which(name, path=environment.get('PATH'))]
    github.require(not missing, 'Missing build tools: ' + ', '.join(missing) + '. See README.md.')
    return environment


def signing_configuration(profile):
    config = ROOT / 'local/release.json'
    settings = json.loads(config.read_text()) if config.exists() else {}
    profile = profile or os.environ.get('NOTARY_PROFILE') or settings.get('notary_profile')
    github.require(isinstance(profile, str) and bool(profile.strip()),
                   'Set NOTARY_PROFILE, --notary-profile, or notary_profile in ignored local/release.json.')
    result = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                            capture_output=True, text=True, check=True)
    identities = re.findall(r'\b([A-Fa-f0-9]{40})\s+"Developer ID Application:[^"]+"', result.stdout)
    identity = os.environ.get('SIGN_IDENTITY')
    if identity:
        github.require(identity in identities, 'SIGN_IDENTITY must be a valid Developer ID certificate SHA-1.')
    else:
        github.require(len(identities) == 1, 'Expected one valid Developer ID Application identity; otherwise set SIGN_IDENTITY to its SHA-1.')
        identity = identities[0]
    args = ['xcrun', 'notarytool', 'history', '--keychain-profile', profile, '--output-format', 'json']
    keychain = os.environ.get('NOTARY_KEYCHAIN')
    if keychain:
        args += ['--keychain', keychain]
    result = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    github.require(result.returncode == 0, 'The local notarization profile could not authenticate. See docs/DISTRIBUTION.md.')
    return dict(SIGN_IDENTITY=identity, NOTARY_PROFILE=profile,
                **({'NOTARY_KEYCHAIN': keychain} if keychain else {}))


def validate_tag(tag, sha):
    # Do not move a pre-existing tag, including tags without a published release.
    reference = github.api(f'git/ref/tags/{tag}', optional=True)
    if reference:
        github.require(github.api(f'commits/{tag}')['sha'] == sha, 'The existing remote tag identifies another commit.')
    return reference


def wait_for_ci(sha, work):
    result = subprocess.check_output(['gh', 'run', 'list', '--repo', github.REPOSITORY,
                                     '--workflow', 'ci.yml', '--commit', sha, '--event', 'push', '--limit', '10',
                                     '--json', 'databaseId,status,conclusion'], text=True)
    runs = json.loads(result)
    github.require(bool(runs), 'No macOS checks run exists for this main commit. Push main and wait for GitHub Actions.')
    run = runs[0]
    if run['status'] != 'completed':
        print('Waiting for Apple Silicon and Intel CI checks...', flush=True)
        subprocess.run(['gh', 'run', 'watch', str(run['databaseId']), '--repo', github.REPOSITORY,
                        '--interval', '15', '--exit-status'], cwd=work, check=True)
    else:
        github.require(run['conclusion'] == 'success', 'The latest macOS checks run did not succeed. Fix CI before publishing.')


def create_tag(tag, sha, source):
    github.validate_new_version(tag)
    if not validate_tag(tag, sha):
        github.api('git/refs', 'POST', dict(ref=f'refs/tags/{tag}', sha=sha))
    # Fetch only this tag into the isolated clone. Never force or modify a tag.
    subprocess.run(['git', 'fetch', '--quiet', 'origin', f'refs/tags/{tag}:refs/tags/{tag}'], cwd=source, check=True)


def run_step(label, args, source, environment, directory):
    log = directory / f'{label}.log'
    print(f'{label}...', flush=True)
    with log.open('w') as output:
        result = subprocess.run(args, cwd=source, env=environment, stdout=output, stderr=subprocess.STDOUT, check=False)
    github.require(result.returncode == 0, f'{label} failed. Inspect {log}. Nothing further was published.')


def execute(args):
    github.require(sys.platform == 'darwin', 'Local releases require macOS, full Xcode and a Developer ID identity.')
    environment = build_environment()
    sha = validate_checkout()
    tag = github.source_tag()
    github.release_notes(tag)
    # gh uses its existing local login; no Apple credentials are exported or uploaded.
    result = subprocess.run(['gh', 'auth', 'status', '--hostname', 'github.com'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    github.require(result.returncode == 0, 'Authenticate GitHub CLI locally with gh auth login.')
    if args.publish:
        github.validate_new_version(tag)
        validate_tag(tag, sha)
    signing = signing_configuration(args.notary_profile)
    if args.check:
        print(f'{tag}: source, tools, GitHub login and local Keychain notarization are ready. No build or publication performed.')
        return
    directory = Path(tempfile.mkdtemp(prefix='local-release.', dir=ROOT / '.build'))
    source = directory / 'source'
    print(f'Clean release workspace: {directory}', flush=True)
    subprocess.run(['git', 'clone', '--quiet', '--no-local', '--branch', 'main', str(ROOT), str(source)], check=True)
    github.require(git('rev-parse', 'HEAD', cwd=source) == sha, 'main changed while creating the snapshot. Retry.')
    subprocess.run(['git', 'remote', 'set-url', 'origin', f'https://github.com/{github.REPOSITORY}.git'], cwd=source, check=True)
    old_root = github.ROOT
    github.ROOT = source
    try:
        for label, command in [
            ('publication-before', [sys.executable, 'scripts/check-public-repo.py']),
            ('automation-tests', [sys.executable, 'scripts/test-github-release.py']),
            ('build', ['bash', 'scripts/build.sh']),
            ('smoke', ['bash', 'scripts/smoke.sh']),
            ('tests', ['bash', 'scripts/test.sh']),
            ('publication-after', [sys.executable, 'scripts/check-public-repo.py']),
        ]:
            run_step(label, command, source, environment, directory)
        github.require(not git('status', '--porcelain', cwd=source), 'Build or tests changed published source files.')
        package_environment = dict(environment, **signing, SKIP_BUILD='1', REQUIRE_NOTARIZATION='1')
        run_step('signed-package', ['bash', 'scripts/package.sh'], source, package_environment, directory)
        github.local_assets(tag)
        print('Developer ID, notarization, both stapled tickets, Gatekeeper and checksum verified.', flush=True)
        if args.publish:
            wait_for_ci(sha, source)
            subprocess.run(['git', 'fetch', '--quiet', 'origin', 'main'], cwd=source, check=True)
            create_tag(tag, sha, source)
            github.publish(tag)
            github.verify_download(tag)
        report = dict(commit=sha, tag=tag, published=args.publish, public_distribution_ready=True,
                      artifacts=str(source / 'dist'))
        (directory / 'release.json').write_text(json.dumps(report, indent=2) + '\n')
        (ROOT / '.build/last-local-release.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f'Artifacts: {source / "dist"}')
        if not args.publish:
            print('Signed rehearsal complete. No GitHub tag, release or asset was created or changed.')
    finally:
        github.ROOT = old_root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--publish', action='store_true', help='Create the version tag and publish the verified DMG as Latest.')
    parser.add_argument('--check', action='store_true', help='Run preflight checks only; do not build or publish.')
    parser.add_argument('--notary-profile', help='Existing local notarytool Keychain profile; no password is read or exported.')
    args = parser.parse_args()
    (ROOT / '.build').mkdir(exist_ok=True)
    with (ROOT / '.build/local-release.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit('Another local release is already running.')
        execute(args)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
