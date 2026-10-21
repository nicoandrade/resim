#!/usr/bin/env python3
"""Exercise release failure paths without signing credentials or GitHub writes."""

import copy
import base64
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('github_release', Path(__file__).with_name('github-release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
sign_spec = importlib.util.spec_from_file_location('ci_sign_package', Path(__file__).with_name('ci-sign-package.py'))
signer = importlib.util.module_from_spec(sign_spec)
sign_spec.loader.exec_module(signer)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ('scripts', '.build', 'dist'):
            (self.root / name).mkdir()
        (self.root / 'scripts/generate-project.py').write_text("base_settings = dict(MARKETING_VERSION='0.2.0')\n")
        (self.root / 'CHANGELOG.md').write_text('# Changelog\n\n## Unreleased\n\n## 0.2.0 - 2026-10-21\n\n### Fixed\n\n- A fix.\n\n## 0.1.0 - 2026-10-20\n\n- Old notes.\n')
        self.sha = 'a' * 40
        self.environment = dict(GITHUB_REPOSITORY=release.REPOSITORY, GITHUB_SHA=self.sha,
                                GITHUB_EVENT_NAME='push', GITHUB_REF='refs/tags/v0.2.0', RELEASE_TAG='v0.2.0')
        self.addCleanup(patch.stopall)
        patch.object(release, 'ROOT', self.root).start()
        patch.dict(os.environ, self.environment, clear=True).start()
        patch('sys.stdout', new=io.StringIO()).start()
        patch.object(release, 'command', return_value=self.sha).start()
        self.run = patch.object(release.subprocess, 'run').start()
        self.requests = []
        self.draft = None
        self.latest = dict(tag_name='v0.1.0')
        self.assets, self.hashes = self.package()
        patch.object(release, 'api', side_effect=self.api).start()

    def package(self):
        dmg = self.root / 'dist/Resim.dmg'
        dmg.write_bytes(b'final signed and stapled test bytes')
        digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
        (self.root / 'dist/Resim.dmg.sha256').write_text(f'{digest}  Resim.dmg\n')
        (self.root / '.build/package-verification.json').write_text(json.dumps(dict(
            public_distribution_ready=True, version='0.2.0', dmg_sha256=digest)))
        return release.local_assets('v0.2.0')

    def api(self, path, method='GET', data=None, optional=False):
        self.requests.append((path, method, data))
        if path == 'commits/v0.2.0':
            return dict(sha=self.sha)
        if path == 'releases/latest':
            return self.latest
        if path == 'releases/tags/v0.2.0':
            return copy.deepcopy(self.draft)
        if path == 'releases' and method == 'POST':
            self.draft = dict(data, id=42, assets=[])
            return copy.deepcopy(self.draft)
        if path == 'releases/42' and method == 'GET':
            self.draft['assets'] = [dict(name=p.name, size=p.stat().st_size, state='uploaded',
                                         digest=f'sha256:{self.hashes[p.name]}') for p in self.assets]
            return copy.deepcopy(self.draft)
        if path == 'releases/42' and method == 'PATCH':
            self.draft.update(data, html_url='https://example.invalid/release')
            self.latest = dict(tag_name='v0.2.0')
            return self.draft
        self.fail(f'Unexpected API request: {method} {path}')

    def test_publish_verifies_draft_before_advancing_latest(self):
        release.publish()
        self.assertFalse(self.draft['draft'])
        self.assertEqual(self.draft['make_latest'], 'true')
        mutations = [(path, method) for path, method, _ in self.requests if method != 'GET']
        self.assertEqual(mutations, [('releases', 'POST'), ('releases/42', 'PATCH')])
        self.run.assert_any_call(['gh', 'release', 'upload', 'v0.2.0', *map(str, self.assets),
                                  '--repo', release.REPOSITORY], cwd=self.root, check=True)

    def test_tag_version_mismatch_never_writes(self):
        os.environ['RELEASE_TAG'] = 'v0.3.0'
        os.environ['GITHUB_REF'] = 'refs/tags/v0.3.0'
        with self.assertRaisesRegex(RuntimeError, 'app version'):
            release.publish()
        self.assertEqual(self.requests, [])

    def test_existing_public_release_is_never_modified(self):
        self.draft = dict(draft=False)
        with self.assertRaisesRegex(RuntimeError, 'already published'):
            release.publish()
        self.assertTrue(all(method == 'GET' for _, method, _ in self.requests))

    def test_older_version_cannot_replace_latest(self):
        self.latest = dict(tag_name='v0.3.0')
        with self.assertRaisesRegex(RuntimeError, 'downgrade'):
            release.publish()
        self.assertTrue(all(method == 'GET' for _, method, _ in self.requests))

    def test_missing_notarization_never_creates_draft(self):
        report = self.root / '.build/package-verification.json'
        report.write_text(json.dumps(dict(public_distribution_ready=False)))
        with self.assertRaisesRegex(RuntimeError, 'notarized'):
            release.publish()
        self.assertTrue(all(method == 'GET' for _, method, _ in self.requests))

    def test_tampered_dmg_and_wrong_checksum_are_rejected(self):
        (self.root / 'dist/Resim.dmg').write_bytes(b'tampered')
        with self.assertRaisesRegex(RuntimeError, 'changed after'):
            release.local_assets('v0.2.0')
        self.package()
        (self.root / 'dist/Resim.dmg.sha256').write_text('wrong\n')
        with self.assertRaisesRegex(RuntimeError, 'Checksum'):
            release.local_assets('v0.2.0')

    def test_incomplete_or_mismatched_upload_cannot_publish(self):
        for assets in [[], [dict(name='Resim.dmg', size=1, state='uploaded', digest='sha256:wrong'),
                           dict(name='Resim.dmg.sha256', size=76, state='uploaded')]]:
            with self.assertRaises(RuntimeError):
                release.verify_uploaded(dict(assets=assets), self.assets, self.hashes)

    def test_failed_upload_verification_leaves_previous_latest(self):
        with patch.object(release, 'verify_uploaded', side_effect=RuntimeError('upload digest mismatch')):
            with self.assertRaisesRegex(RuntimeError, 'digest mismatch'):
                release.publish()
        self.assertTrue(self.draft['draft'])
        self.assertEqual(self.latest['tag_name'], 'v0.1.0')
        self.assertFalse(any(method == 'PATCH' for _, method, _ in self.requests))

    def test_manual_rehearsal_does_not_contact_release_api(self):
        os.environ.update(GITHUB_EVENT_NAME='workflow_dispatch', GITHUB_REF='refs/heads/main')
        release.prepare()
        self.assertEqual(self.requests, [])
        self.assertIn('A fix.', (self.root / '.build/release-notes.md').read_text())
        self.assertNotIn('Old notes.', (self.root / '.build/release-notes.md').read_text())
        with self.assertRaisesRegex(RuntimeError, 'matching tag push'):
            release.publish()

    def test_prerelease_and_invalid_tags_are_rejected(self):
        for tag in ['0.2.0', 'v0.2.0-rc.1', 'v01.2.0', 'v0.2.0;echo x']:
            with self.assertRaises(RuntimeError):
                release.version_tuple(tag)


class SigningCleanupTests(unittest.TestCase):
    def test_wrapped_certificate_package_environment_and_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / '.build').mkdir()
            (root / '.build/package-verification.json').write_text(json.dumps(dict(public_distribution_ready=True)))
            environment = {name: 'test-value' for name in signer.SECRET_NAMES}
            environment.update(GITHUB_ACTIONS='true', RUNNER_TEMP=temporary,
                               DEVELOPER_ID_P12_BASE64=base64.encodebytes(b'fake-certificate').decode())
            calls = []

            def private(*args):
                calls.append(args)
                if args[1] == 'list-keychains' and '-s' not in args:
                    return '"original.keychain-db"'
                if args[1] == 'find-identity':
                    return f'1) {"A" * 40} "Developer ID Application: Test"'
                if args[1] == 'import':
                    self.assertEqual(Path(args[2]).read_bytes(), b'fake-certificate')
                return ''

            def run(args, **kwargs):
                if args[0] == 'bash':
                    self.assertFalse(set(signer.SECRET_NAMES) & kwargs['env'].keys())
                    self.assertEqual(kwargs['env']['REQUIRE_NOTARIZATION'], '1')
                    self.assertEqual(kwargs['env']['SKIP_BUILD'], '1')
                    self.assertEqual(kwargs['env']['NOTARY_PROFILE'], 'resim-ci')
                return type('Result', (), {'returncode': 0})()

            with patch.dict(os.environ, environment, clear=True), patch.object(signer, 'ROOT', root), \
                    patch.object(signer, 'private_command', side_effect=private), \
                    patch.object(signer.subprocess, 'run', side_effect=run) as subprocess_run, \
                    redirect_stdout(io.StringIO()):
                signer.main()
                self.assertEqual(subprocess_run.call_args.args[0][:2], ['security', 'delete-keychain'])
                self.assertFalse(list(root.glob('resim-signing-*')))

    def test_missing_secrets_stop_before_keychain_commands(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(signer, 'private_command') as private:
            with self.assertRaisesRegex(SystemExit, 'Configure these GitHub'):
                signer.main()
            private.assert_not_called()

    def test_failed_import_removes_temporary_keychain(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment = {name: 'test-value' for name in signer.SECRET_NAMES}
            environment.update(GITHUB_ACTIONS='true', RUNNER_TEMP=temporary,
                               DEVELOPER_ID_P12_BASE64=base64.b64encode(b'fake-certificate').decode())
            calls = []

            def private(*args):
                calls.append(args)
                if args[1] == 'list-keychains' and '-s' not in args:
                    return '"original.keychain-db"'
                if args[1] == 'import':
                    raise RuntimeError('test import failure')
                return ''

            with patch.dict(os.environ, environment, clear=True), \
                    patch.object(signer, 'private_command', side_effect=private), \
                    patch.object(signer.subprocess, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, 'test import failure'):
                    signer.main()
                self.assertIn(('security', 'list-keychains', '-d', 'user', '-s', 'original.keychain-db'), calls)
                self.assertEqual(run.call_args.args[0][:2], ['security', 'delete-keychain'])
                self.assertEqual(list(Path(temporary).iterdir()), [])


if __name__ == '__main__':
    unittest.main()
