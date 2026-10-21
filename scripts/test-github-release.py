#!/usr/bin/env python3
"""Exercise release failure paths without signing credentials or GitHub writes."""

import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('github_release', Path(__file__).with_name('github-release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
local_spec = importlib.util.spec_from_file_location('local_release', Path(__file__).with_name('release.py'))
local = importlib.util.module_from_spec(local_spec)
local_spec.loader.exec_module(local)


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
        self.addCleanup(patch.stopall)
        patch.object(release, 'ROOT', self.root).start()
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
        release.publish('v0.2.0')
        self.assertFalse(self.draft['draft'])
        self.assertEqual(self.draft['make_latest'], 'true')
        mutations = [(path, method) for path, method, _ in self.requests if method != 'GET']
        self.assertEqual(mutations, [('releases', 'POST'), ('releases/42', 'PATCH')])
        self.run.assert_any_call(['gh', 'release', 'upload', 'v0.2.0', *map(str, self.assets),
                                  '--repo', release.REPOSITORY], cwd=self.root, check=True)

    def test_tag_version_mismatch_never_writes(self):
        with self.assertRaisesRegex(RuntimeError, 'app version'):
            release.publish('v0.3.0')
        self.assertEqual(self.requests, [])

    def test_existing_public_release_is_never_modified(self):
        self.draft = dict(draft=False)
        with self.assertRaisesRegex(RuntimeError, 'already published'):
            release.publish('v0.2.0')
        self.assertTrue(all(method == 'GET' for _, method, _ in self.requests))

    def test_older_version_cannot_replace_latest(self):
        self.latest = dict(tag_name='v0.3.0')
        with self.assertRaisesRegex(RuntimeError, 'downgrade'):
            release.publish('v0.2.0')
        self.assertTrue(all(method == 'GET' for _, method, _ in self.requests))

    def test_missing_notarization_never_creates_draft(self):
        report = self.root / '.build/package-verification.json'
        report.write_text(json.dumps(dict(public_distribution_ready=False)))
        with self.assertRaisesRegex(RuntimeError, 'notarized'):
            release.publish('v0.2.0')
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
                release.publish('v0.2.0')
        self.assertTrue(self.draft['draft'])
        self.assertEqual(self.latest['tag_name'], 'v0.1.0')
        self.assertFalse(any(method == 'PATCH' for _, method, _ in self.requests))

    def test_notes_include_only_this_release_and_do_not_mutate_github(self):
        notes = release.release_notes('v0.2.0')
        self.assertIn('A fix.', notes)
        self.assertNotIn('Old notes.', notes)
        self.assertEqual(self.requests, [])

    def test_prerelease_and_invalid_tags_are_rejected(self):
        for tag in ['0.2.0', 'v0.2.0-rc.1', 'v01.2.0', 'v0.2.0;echo x']:
            with self.assertRaises(RuntimeError):
                release.version_tuple(tag)



class LocalReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.addCleanup(patch.stopall)
        patch.object(local, 'ROOT', self.root).start()
        self.api = patch.object(local.github, 'api').start()

    def test_preflight_rejects_unrelated_origin_before_fetching(self):
        with patch.object(local, 'git', return_value='https://github.com/example/other.git'), \
                patch.object(local.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'intended GitHub'):
                local.validate_checkout()
            run.assert_not_called()

    def test_preflight_rejects_uncommitted_source(self):
        with patch.object(local, 'git', side_effect=[f'https://github.com/{local.github.REPOSITORY}.git', 'main']), \
                patch.object(local, 'source_is_clean', return_value=False), \
                patch.object(local.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'Commit and push'):
                local.validate_checkout()
            run.assert_not_called()

    def test_source_comparison_uses_git_content_and_rejects_untracked_files(self):
        with patch.object(local.subprocess, 'run', return_value=SimpleNamespace(returncode=0)) as run, \
                patch.object(local, 'git', return_value='') as git:
            self.assertTrue(local.source_is_clean(self.root))
            self.assertEqual(run.call_args.args[0], ['git', 'diff', '--quiet', 'HEAD'])
            git.assert_called_once_with('ls-files', '--others', '--exclude-standard', '-z', cwd=self.root)
            git.return_value = 'unexpected-file\0'
            self.assertFalse(local.source_is_clean(self.root))
        with patch.object(local.subprocess, 'run', return_value=SimpleNamespace(returncode=1)):
            self.assertFalse(local.source_is_clean(self.root))

    def test_existing_keychain_profile_is_used_without_export(self):
        (self.root / 'local').mkdir()
        (self.root / 'local/release.json').write_text(json.dumps(dict(notary_profile='test-profile')))
        identity = 'A' * 40
        result = SimpleNamespace(returncode=0, stdout=f'1) {identity} "Developer ID Application: Test"')
        with patch.dict(local.os.environ, {}, clear=True), patch.object(local.subprocess, 'run', return_value=result) as run:
            config = local.signing_configuration(None)
            self.assertEqual(config, dict(SIGN_IDENTITY=identity, NOTARY_PROFILE='test-profile'))
            self.assertEqual(run.call_args_list[0].args[0], ['security', 'find-identity', '-v', '-p', 'codesigning'])
            self.assertEqual(run.call_args_list[1].args[0], ['xcrun', 'notarytool', 'history', '--keychain-profile',
                                                           'test-profile', '--output-format', 'json'])
            self.assertFalse(any('export' in call.args[0] for call in run.call_args_list))
        self.api.assert_not_called()

    def test_ambiguous_signing_identity_fails_before_notarization(self):
        identities = '\n'.join(f'1) {letter * 40} "Developer ID Application: Test"' for letter in ('A', 'B'))
        with patch.dict(local.os.environ, {}, clear=True), \
                patch.object(local.subprocess, 'run', return_value=SimpleNamespace(stdout=identities)) as run:
            with self.assertRaisesRegex(RuntimeError, 'one valid Developer ID'):
                local.signing_configuration('test-profile')
            self.assertEqual(run.call_count, 1)

    def test_failed_notary_authentication_stops_preflight(self):
        results = [SimpleNamespace(stdout=f'1) {"A" * 40} "Developer ID Application: Test"'), SimpleNamespace(returncode=1)]
        with patch.dict(local.os.environ, {}, clear=True), patch.object(local.subprocess, 'run', side_effect=results):
            with self.assertRaisesRegex(RuntimeError, 'could not authenticate'):
                local.signing_configuration('test-profile')
        self.api.assert_not_called()

    def test_conflicting_remote_tag_is_never_moved(self):
        self.api.side_effect = [dict(object=dict(sha='old')), dict(sha='old')]
        with self.assertRaisesRegex(RuntimeError, 'another commit'):
            local.validate_tag('v0.2.0', 'new')
        self.assertTrue(all(call.kwargs.get('method', 'GET') == 'GET' for call in self.api.call_args_list))

    def test_tag_creation_requires_new_version_and_does_not_force_fetch(self):
        self.api.side_effect = [None, dict(tag_name='v0.1.0'), None, dict(ref='refs/tags/v0.2.0')]
        with patch.object(local.subprocess, 'run') as run:
            local.create_tag('v0.2.0', 'sha', self.root)
        self.api.assert_any_call('git/refs', 'POST', dict(ref='refs/tags/v0.2.0', sha='sha'))
        run.assert_called_once_with(['git', 'fetch', '--quiet', 'origin', 'refs/tags/v0.2.0:refs/tags/v0.2.0'],
                                    cwd=self.root, check=True)

    def test_failed_ci_blocks_publication(self):
        result = json.dumps([dict(databaseId=1, status='completed', conclusion='failure')])
        with patch.object(local.subprocess, 'check_output', return_value=result):
            with self.assertRaisesRegex(RuntimeError, 'Fix CI'):
                local.wait_for_ci('sha', self.root)
        self.api.assert_not_called()

    def test_failed_build_does_not_create_github_tag_or_release(self):
        with patch.object(local.subprocess, 'run', return_value=SimpleNamespace(returncode=1)):
            with self.assertRaisesRegex(RuntimeError, 'build failed'):
                local.run_step('build', ['bash', 'scripts/build.sh'], self.root, {}, self.root)
        self.api.assert_not_called()

    def orchestration(self, publishing):
        (self.root / '.build').mkdir()
        events = []
        def step(label, command, source, environment, directory):
            events.append(label)
            if label == 'signed-package':
                self.assertEqual(environment['REQUIRE_NOTARIZATION'], '1')
                self.assertEqual(environment['SKIP_BUILD'], '1')
                self.assertEqual(environment['NOTARY_PROFILE'], 'test-profile')
            else:
                self.assertNotIn('SIGN_IDENTITY', environment)
        with patch.object(local.sys, 'platform', 'darwin'), \
                patch.object(local, 'build_environment', return_value={}), \
                patch.object(local, 'validate_checkout', return_value='sha'), \
                patch.object(local, 'source_is_clean', return_value=True), \
                patch.object(local.github, 'source_tag', return_value='v0.2.0'), \
                patch.object(local.github, 'release_notes'), \
                patch.object(local.github, 'validate_new_version'), \
                patch.object(local, 'validate_tag'), \
                patch.object(local, 'signing_configuration', return_value=dict(SIGN_IDENTITY='identity', NOTARY_PROFILE='test-profile')), \
                patch.object(local.subprocess, 'run', return_value=SimpleNamespace(returncode=0)), \
                patch.object(local, 'git', return_value='sha'), \
                patch.object(local, 'run_step', side_effect=step), \
                patch.object(local.github, 'local_assets', side_effect=lambda tag: events.append('verified')), \
                patch.object(local, 'wait_for_ci', side_effect=lambda *a: events.append('ci')), \
                patch.object(local, 'create_tag', side_effect=lambda *a: events.append('tag')), \
                patch.object(local.github, 'publish', side_effect=lambda tag: events.append('publish')), \
                patch.object(local.github, 'verify_download', side_effect=lambda tag: events.append('download')), \
                patch('sys.stdout', new=io.StringIO()):
            local.execute(SimpleNamespace(publish=publishing, check=False, notary_profile=None))
        return events

    def test_rehearsal_signs_and_verifies_without_tag_or_publication(self):
        events = self.orchestration(False)
        self.assertEqual(events[-2:], ['signed-package', 'verified'])
        self.assertNotIn('tag', events)
        self.assertNotIn('publish', events)
        self.api.assert_not_called()

    def test_publication_is_ordered_after_package_verification_and_ci(self):
        events = self.orchestration(True)
        self.assertEqual(events[-6:], ['signed-package', 'verified', 'ci', 'tag', 'publish', 'download'])


if __name__ == '__main__':
    unittest.main()
