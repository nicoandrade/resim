#!/usr/bin/env python3
"""Validate stable releases, publish verified packages, and check public downloads."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'nicoandrade/resim'
ASSETS = ('Resim.dmg', 'Resim.dmg.sha256')


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def api(path, method='GET', data=None, optional=False):
    args = ['gh', 'api', f'repos/{REPOSITORY}/{path}', '--method', method]
    if data is not None:
        args += ['--input', '-']
    result = subprocess.run(args, input=json.dumps(data) if data is not None else None,
                            capture_output=True, text=True, cwd=ROOT, check=False)
    if optional and result.returncode and 'HTTP 404' in result.stderr:
        return None
    require(result.returncode == 0, f'GitHub API failed ({method} {path}): {result.stderr.strip()}')
    return json.loads(result.stdout) if result.stdout.strip() else None


def version_tuple(tag):
    require(re.fullmatch(r'v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', tag),
            'Only stable vMAJOR.MINOR.PATCH tags are supported.')
    return tuple(map(int, tag[1:].split('.')))


def source_tag():
    versions = re.findall(r"\bMARKETING_VERSION='([^']+)'", (ROOT / 'scripts/generate-project.py').read_text())
    require(len(versions) == 1, 'Expected one authoritative MARKETING_VERSION.')
    tag = f'v{versions[0]}'
    version_tuple(tag)
    return tag


def release_notes(tag):
    heading = rf'^## (?:\[)?{re.escape(tag[1:])}(?:\])? - \d{{4}}-\d{{2}}-\d{{2}}\s*$'
    text = (ROOT / 'CHANGELOG.md').read_text()
    entries = list(re.finditer(heading, text, re.MULTILINE))
    require(len(entries) == 1, 'Add exactly one dated CHANGELOG entry matching the release tag.')
    body = re.split(r'^## ', text[entries[0].end():], maxsplit=1, flags=re.MULTILINE)[0].strip()
    require(bool(body), 'Release notes cannot be empty.')
    return body + '\n\nDownload `Resim.dmg` and verify it with `shasum -a 256 -c Resim.dmg.sha256`.\n'


def validate_source(tag, publishing):
    require(os.environ.get('GITHUB_REPOSITORY', REPOSITORY) == REPOSITORY, 'Unexpected repository.')
    require(tag == source_tag(), 'Tag and authoritative app version do not match.')
    sha = command('git', 'rev-parse', 'HEAD')
    require(sha == os.environ.get('GITHUB_SHA', sha), 'Checkout does not match the workflow commit.')
    subprocess.run(['git', 'merge-base', '--is-ancestor', sha, 'refs/remotes/origin/main'],
                   cwd=ROOT, check=True)
    if publishing:
        require(command('git', 'rev-parse', f'refs/tags/{tag}^{{commit}}') == sha,
                'Release tag must identify the checked-out main commit.')
        require(api(f'commits/{tag}')['sha'] == sha, 'Remote tag changed; refusing to publish.')
        existing = api(f'releases/tags/{tag}', optional=True)
        require(existing is None or existing['draft'], 'This version is already published; never overwrite it.')
        latest = api('releases/latest', optional=True)
        require(latest is None or version_tuple(tag) > version_tuple(latest['tag_name']),
                'Version must be newer than Latest; refusing to downgrade the landing download.')
    return sha


def local_assets(tag):
    report = json.loads((ROOT / '.build/package-verification.json').read_text())
    require(report.get('public_distribution_ready') is True, 'Signed, stapled, notarized verification is required.')
    require(report.get('version') == tag[1:], 'Verified package version does not match the tag.')
    paths = [ROOT / 'dist' / name for name in ASSETS]
    hashes = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    require(hashes['Resim.dmg'] == report['dmg_sha256'], 'DMG changed after package verification.')
    require(paths[1].read_text() == f"{hashes['Resim.dmg']}  Resim.dmg\n", 'Checksum must name and match Resim.dmg.')
    return paths, hashes


def verify_uploaded(release, paths, hashes):
    assets = {asset['name']: asset for asset in release['assets']}
    require(set(assets) == set(ASSETS), 'The draft must contain exactly the DMG and its checksum.')
    for path in paths:
        asset = assets[path.name]
        require(asset['state'] == 'uploaded' and asset['size'] == path.stat().st_size,
                f'Incomplete upload: {path.name}')
        require(asset.get('digest') == f'sha256:{hashes[path.name]}', f'Uploaded digest mismatch: {path.name}')


def prepare():
    publishing = os.environ.get('GITHUB_EVENT_NAME') == 'push'
    tag = source_tag()
    if publishing:
        require(os.environ.get('GITHUB_REF') == f'refs/tags/{tag}', 'Push a stable tag matching the app version.')
    else:
        require(os.environ.get('GITHUB_REF', 'refs/heads/main') == 'refs/heads/main',
                'Manual rehearsals must run from main.')
    validate_source(tag, publishing)
    notes = release_notes(tag)
    (ROOT / '.build').mkdir(exist_ok=True)
    (ROOT / '.build/release-notes.md').write_text(notes)
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(f'tag={tag}\n')
    print(f'{tag}: source and release notes validated; publish={publishing}.')


def publish():
    tag = os.environ['RELEASE_TAG']
    require(os.environ.get('GITHUB_EVENT_NAME') == 'push'
            and os.environ.get('GITHUB_REF') == f'refs/tags/{tag}', 'Publication requires a matching tag push.')
    sha = validate_source(tag, True)
    paths, hashes = local_assets(tag)
    notes = release_notes(tag)
    draft = api(f'releases/tags/{tag}', optional=True)
    if draft is None:
        draft = api('releases', 'POST', dict(tag_name=tag, target_commitish=sha, name=tag,
                                           body=notes, draft=True, prerelease=False, make_latest='false'))
    require(draft['draft'] and not draft['prerelease'] and draft['target_commitish'] == sha,
            'Only a draft for this exact commit can be resumed.')
    require(all(asset['name'] in ASSETS for asset in draft['assets']), 'Unexpected draft assets; inspect manually.')
    # Retry incomplete drafts safely. Published releases were rejected above.
    for asset in draft['assets']:
        api(f"releases/assets/{asset['id']}", 'DELETE')
    subprocess.run(['gh', 'release', 'upload', tag, *map(str, paths), '--repo', REPOSITORY], cwd=ROOT, check=True)
    draft = api(f"releases/{draft['id']}")
    verify_uploaded(draft, paths, hashes)
    # Recheck the remote tag and Latest after the upload, immediately before publication.
    validate_source(tag, True)
    result = api(f"releases/{draft['id']}", 'PATCH', dict(body=notes, draft=False, prerelease=False, make_latest='true'))
    require(not result['draft'] and not result['prerelease'], 'GitHub did not publish the stable release.')
    require(api('releases/latest')['tag_name'] == tag, 'GitHub did not advance Latest to this tag.')
    print(result['html_url'])


def verify_download():
    tag = os.environ.get('RELEASE_TAG', source_tag())
    _, hashes = local_assets(tag)
    base = f'https://github.com/{REPOSITORY}/releases/latest/download/'
    # Deliberately use no GitHub credentials: this is the landing visitor's URL.
    for attempt in range(5):
        try:
            for name in ASSETS:
                request = urllib.request.Request(base + name, headers={'User-Agent': 'Resim-release-check'})
                digest = hashlib.sha256()
                with urllib.request.urlopen(request, timeout=120) as response:
                    while chunk := response.read(1024 * 1024):
                        digest.update(chunk)
                require(digest.hexdigest() == hashes[name], f'Public download mismatch: {name}')
            print(f'{tag}: anonymous Latest DMG and checksum match the verified package.')
            return
        except (OSError, RuntimeError):
            if attempt == 4:
                raise
            time.sleep(3 * 2 ** attempt)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'publish', 'verify-download'])
    action = parser.parse_args().action
    {'prepare': prepare, 'publish': publish, 'verify-download': verify_download}[action]()


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
