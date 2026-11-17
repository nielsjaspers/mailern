import base64
import hashlib
import json
import plistlib
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import builds


class ConcurrentAPI:
    """Model GitHub's file-SHA precondition with independent simultaneous readers."""
    def __init__(self, readers=1):
        self.data = {'schema': 1, 'builds': [{'build': 36, 'version': '0.6.0', 'status': 'reported'}]}
        self.sha = 0
        self.lock = threading.Lock()
        self.barrier = threading.Barrier(readers)
        self.first_reads = readers
        self.conflicts = 0

    def __call__(self, repo, endpoint, method='GET', payload=None):
        with self.lock:
            if method == 'GET':
                result = {'sha': str(self.sha), 'content': base64.b64encode(json.dumps(self.data).encode()).decode()}
                wait = self.first_reads > 0
                self.first_reads -= int(wait)
            else:
                if payload['sha'] != str(self.sha):
                    self.conflicts += 1
                    raise builds.APIError(subprocess.CompletedProcess([], 1, '', 'gh: conflict (HTTP 409)'))
                self.data = json.loads(base64.b64decode(payload['content']))
                self.sha += 1
                return {}
        if wait:
            self.barrier.wait(timeout=10)
        return result


class RegistryTests(unittest.TestCase):
    def test_competing_machines_get_unique_numbers_and_preserve_every_record(self):
        api = ConcurrentAPI(readers=8)
        with patch.object(builds, 'api', api), ThreadPoolExecutor(max_workers=8) as pool:
            reservations = list(pool.map(lambda number: builds.Registry('owner/repo').reserve(
                '0.6.1', {'source_digest': str(number), 'source_revision': 'a' * 40}), range(8)))
        self.assertEqual(sorted(record['build'] for record in reservations), list(range(37, 45)))
        self.assertEqual(len(api.data['builds']), 9)
        self.assertGreater(api.conflicts, 0)

    def test_failed_and_abandoned_numbers_are_never_reused(self):
        api = ConcurrentAPI()
        registry = builds.Registry('owner/repo')
        with patch.object(builds, 'api', api):
            first = registry.reserve('0.6.1', {'source_digest': 'one'})
            failed = dict(first, status='failed')
            registry.finish(failed)
            abandoned = registry.reserve('0.6.1', {'source_digest': 'two'})
            last = registry.reserve('0.6.2', {'source_digest': 'three'})
            self.assertEqual([first['build'], abandoned['build'], last['build']], [37, 38, 39])
            with self.assertRaisesRegex(RuntimeError, 'reservation has changed'):
                registry.finish(dict(failed, status='exported'))

    def test_requested_number_already_taken_does_not_reserve_another_number(self):
        api = ConcurrentAPI()
        with patch.object(builds, 'api', api):
            registry = builds.Registry('owner/repo')
            registry.reserve('0.6.1', {'source_digest': 'one'}, expected=37)
            with self.assertRaisesRegex(RuntimeError, 'Next available build is 38'):
                registry.reserve('0.6.1', {'source_digest': 'two'}, expected=37)
        self.assertEqual(len(api.data['builds']), 2)

    def test_source_change_stops_export_and_records_failure(self):
        api = ConcurrentAPI()
        args = builds.argparse.Namespace(version='0.6.1', expect_build=37, team_id='TEST', bundle_id='test.mail')
        source = {'source_revision': 'a' * 40, 'source_digest': 'before', 'branch': 'feature', 'uncommitted_changes': True}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(builds, 'ROOT', root), patch.object(builds, 'api', api), \
                    patch.object(builds, 'command', return_value='Xcode'), \
                    patch.object(builds, 'source_state', side_effect=[source, dict(source, source_digest='after')]), \
                    patch.object(builds, 'logged') as logged:
                with self.assertRaisesRegex(RuntimeError, 'Source changed during archive'):
                    builds.package(args, builds.Registry('owner/repo'), 'owner/repo')
                self.assertEqual(logged.call_count, 1)
                record = json.loads((root / 'build/releases/37/build.json').read_text())
                self.assertEqual(record['status'], 'failed')
                self.assertEqual(api.data['builds'][-1]['status'], 'failed')


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive_info = self.root / 'Mailern.xcarchive/Products/Applications/Mailern.app/Info.plist'
        self.archive_info.parent.mkdir(parents=True)
        self.info = {'CFBundleDisplayName': 'Mailern', 'CFBundleName': 'Mailern',
                     'CFBundleIdentifier': 'test.mail', 'CFBundleShortVersionString': '0.6.1', 'CFBundleVersion': '37'}
        self.archive_info.write_bytes(plistlib.dumps(self.info))
        self.ipa = self.root / 'export/Mailern.ipa'
        self.ipa.parent.mkdir()
        with zipfile.ZipFile(self.ipa, 'w') as package:
            package.writestr('Payload/Mailern.app/Info.plist', plistlib.dumps(self.info))
        self.record = {'status': 'exported', 'version': '0.6.1', 'build': 37, 'bundle_id': 'test.mail',
                       'source_revision': 'a' * 40, 'uncommitted_changes': True,
                       'ipa_sha256': hashlib.sha256(self.ipa.read_bytes()).hexdigest()}
        self.output = self.root / 'install'

    def generate(self):
        record_path = self.root / 'build.json'
        record_path.write_text(json.dumps(self.record))
        script = Path(builds.__file__).with_name('serve-demo.py')
        return subprocess.run([sys.executable, str(script), 'https://example.test/mail', str(self.output),
                               '--build-record', str(record_path)], capture_output=True, text=True)

    def test_older_build_publication_uses_captured_source_and_versions(self):
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        page = (self.output / 'index.html').read_text()
        self.assertIn('0.6.1 · Build 37', page)
        self.assertIn('Source aaaaaaa · Includes uncommitted changes', page)
        manifest = plistlib.loads((self.output / 'manifest-37.plist').read_bytes())
        self.assertEqual(manifest['items'][0]['assets'][0]['url'], 'https://example.test/mail/Mailern-37.ipa')
        self.assertEqual((self.output / 'Mailern-37.ipa').read_bytes(), self.ipa.read_bytes())

    def test_wrong_archive_and_modified_ipa_are_rejected_before_publication(self):
        changed = dict(self.info, CFBundleVersion='36')
        self.archive_info.write_bytes(plistlib.dumps(changed))
        self.assertIn('IPA and archive disagree', self.generate().stderr)
        self.assertFalse(self.output.exists())
        self.archive_info.write_bytes(plistlib.dumps(self.info))
        self.ipa.write_bytes(b'wrong package')
        self.assertIn('IPA checksum does not match', self.generate().stderr)
        self.assertFalse(self.output.exists())

    def test_reusing_a_build_number_with_different_content_preserves_published_ipa(self):
        self.output.mkdir()
        existing = self.output / 'Mailern-37.ipa'
        existing.write_bytes(b'original')
        self.assertIn('already exists with different content', self.generate().stderr)
        self.assertEqual(existing.read_bytes(), b'original')


if __name__ == '__main__':
    unittest.main()
