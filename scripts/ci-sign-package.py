#!/usr/bin/env python3
"""Import GitHub environment secrets into an ephemeral macOS signing keychain."""

import base64
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SECRET_NAMES = ('DEVELOPER_ID_P12_BASE64', 'DEVELOPER_ID_P12_PASSWORD',
                'NOTARY_APPLE_ID', 'NOTARY_APP_PASSWORD', 'NOTARY_TEAM_ID')


def private_command(*args):
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    if result.returncode:
        # Commands may print the signing identity or Apple account. Keep them out of CI logs.
        raise RuntimeError(f'{args[0]} {args[1]} failed. Check the release environment credentials.')
    return result.stdout


def main():
    missing = [name for name in SECRET_NAMES if not os.environ.get(name)]
    if missing:
        raise SystemExit('Configure these GitHub release environment secrets: ' + ', '.join(missing))
    if os.environ.get('GITHUB_ACTIONS') != 'true' or not os.environ.get('RUNNER_TEMP'):
        raise SystemExit('This script is only for ephemeral GitHub-hosted macOS runners.')
    original_keychains = shlex.split(private_command('security', 'list-keychains', '-d', 'user'))
    with tempfile.TemporaryDirectory(prefix='resim-signing-', dir=os.environ['RUNNER_TEMP']) as temporary:
        directory = Path(temporary)
        keychain = str(directory / 'release.keychain-db')
        certificate = directory / 'certificate.p12'
        encoded_certificate = ''.join(os.environ['DEVELOPER_ID_P12_BASE64'].split())
        certificate.write_bytes(base64.b64decode(encoded_certificate, validate=True))
        certificate.chmod(0o600)
        password = secrets.token_urlsafe(32)
        try:
            private_command('security', 'create-keychain', '-p', password, keychain)
            private_command('security', 'set-keychain-settings', '-lut', '21600', keychain)
            private_command('security', 'unlock-keychain', '-p', password, keychain)
            private_command('security', 'import', str(certificate), '-k', keychain, '-P',
                            os.environ['DEVELOPER_ID_P12_PASSWORD'], '-T', '/usr/bin/codesign', '-T', '/usr/bin/security')
            certificate.unlink()
            private_command('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
                            '-s', '-k', password, keychain)
            private_command('security', 'list-keychains', '-d', 'user', '-s', keychain, *original_keychains)
            identities = re.findall(r'\b([A-Fa-f0-9]{40})\s+"Developer ID Application:[^"]+"',
                                    private_command('security', 'find-identity', '-v', '-p', 'codesigning', keychain))
            if len(identities) != 1:
                raise RuntimeError('The P12 must contain exactly one valid Developer ID Application identity and private key.')
            private_command('xcrun', 'notarytool', 'store-credentials', 'resim-ci', '--keychain', keychain,
                            '--apple-id', os.environ['NOTARY_APPLE_ID'], '--team-id', os.environ['NOTARY_TEAM_ID'],
                            '--password', os.environ['NOTARY_APP_PASSWORD'])
            environment = {key: value for key, value in os.environ.items() if key not in SECRET_NAMES}
            environment.update(SIGN_IDENTITY=identities[0], NOTARY_PROFILE='resim-ci', NOTARY_KEYCHAIN=keychain,
                               REQUIRE_NOTARIZATION='1', SKIP_BUILD='1')
            (ROOT / '.build').mkdir(exist_ok=True)
            with (ROOT / '.build/ci-sign-package.log').open('w') as log:
                result = subprocess.run(['bash', 'scripts/package.sh'], cwd=ROOT, env=environment,
                                        stdout=log, stderr=subprocess.STDOUT, check=False)
            if result.returncode:
                raise RuntimeError('Signing, notarization or package verification failed. Nothing was published. '
                                   'Check certificate validity and Apple notarization service status before retrying.')
            report = json.loads((ROOT / '.build/package-verification.json').read_text())
            if report.get('public_distribution_ready') is not True:
                raise RuntimeError('Package failed public distribution verification.')
            print('Developer ID signatures, Universal 2, both stapled tickets and Gatekeeper checks passed.')
        finally:
            try:
                private_command('security', 'list-keychains', '-d', 'user', '-s', *original_keychains)
            finally:
                subprocess.run(['security', 'delete-keychain', keychain], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, check=False)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError) as error:
        raise SystemExit(str(error))
