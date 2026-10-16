#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Pruebas del ciclo de vida con dobles explícitos; no prueban codesign real."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SIGN = Path(__file__).with_name('sign_macos.sh')
DOUBLE = r'''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps([name, args[0] if args else '']) + '\n')
if name == 'security':
    if args[0] == 'list-keychains' and '-s' not in args:
        print('    "/fixture/login.keychain-db"')
    if args[0] == 'create-keychain': pathlib.Path(args[-1]).touch()
    if args[0] == 'delete-keychain': pathlib.Path(args[-1]).unlink()
    if args[0] == 'import' and os.environ.get('FAIL') == 'import': sys.exit(9)
    if args[0] == 'find-certificate': print('MOCK PUBLIC CERTIFICATE, NOT AN IDENTITY')
elif name == 'openssl':
    if args[0] == 'rand': print('mock-ephemeral-passphrase')
    elif '-out' in args: pathlib.Path(args[args.index('-out') + 1]).write_text('MOCK PUBLIC DER')
elif name == 'codesign':
    fail = os.environ.get('FAIL', '')
    if '--force' in args and fail == 'sign': sys.exit(8)
    if '--verify' in args and fail == 'verify': sys.exit(7)
    if '-r-' in args:
        if fail == 'dr': print('designated => cdhash H"0123456789abcdef"')
        else: print('designated => identifier "com.example.fixture" and certificate leaf = H"0123456789abcdef"')
    if '-dvv' in args:
        print('Authority=Other' if fail == 'authority' else 'Authority=NexClip Developer')
'''


class Lifecycle(unittest.TestCase):
    def exercise(self, *, secrets=True, partial=False, fail=''):
        with tempfile.TemporaryDirectory(prefix='sign-tests-') as raw:
            root = Path(raw)
            tools = root / 'bin'
            tools.mkdir()
            for name in ('codesign', 'security', 'openssl'):
                path = tools / name
                path.write_text(f'#!{sys.executable}\n' + DOUBLE)
                path.chmod(0o700)
            calls = root / 'calls.jsonl'
            env = {'PATH': str(tools) + os.pathsep + os.environ['PATH'],
                   'CALLS': str(calls), 'FAIL': fail,
                   'MACOS_CODESIGN_TEMP_DIR': str(root / 'private')}
            if secrets:
                env['MACOS_CODESIGN_P12_BASE64'] = base64.b64encode(b'UNIT TEST MOCK PKCS12').decode()
                if not partial:
                    env['MACOS_CODESIGN_P12_PASSWORD'] = 'unit-test-password-not-a-real-secret'
            cert = root / 'public.cer'
            result = subprocess.run(['bash', str(SIGN), str(root / 'Arbitrary App.app'), str(cert)],
                                    env=env, capture_output=True, text=True)
            events = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertFalse((root / 'private').exists(), result.stdout + result.stderr)
            self.assertNotIn('unit-test-password-not-a-real-secret', result.stdout + result.stderr)
            if secrets and not partial:
                self.assertIn(['security', 'delete-keychain'], events)
                self.assertEqual(sum(e == ['security', 'list-keychains'] for e in events), 3)
            else:
                self.assertFalse(any(e[0] == 'security' for e in events))
            return result, cert.exists()

    def test_stable(self):
        result, cert = self.exercise()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(cert)
        self.assertIn('PASS: stable certificate-based', result.stdout)

    def test_missing_secrets(self):
        result, cert = self.exercise(secrets=False)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(cert)
        self.assertIn('::warning::', result.stdout)

    def test_partial_secrets(self):
        result, cert = self.exercise(partial=True)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(cert)
        self.assertIn('::warning::', result.stdout)

    def test_import_failure_cleanup(self):
        result, _ = self.exercise(fail='import')
        self.assertEqual(result.returncode, 9)

    def test_sign_failure_cleanup(self):
        result, _ = self.exercise(fail='sign')
        self.assertEqual(result.returncode, 8)

    def test_verify_failure_cleanup(self):
        result, _ = self.exercise(fail='verify')
        self.assertEqual(result.returncode, 7)

    def test_reject_cdhash_requirement(self):
        result, _ = self.exercise(fail='dr')
        self.assertNotEqual(result.returncode, 0)

    def test_reject_wrong_authority(self):
        result, _ = self.exercise(fail='authority')
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
