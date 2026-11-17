#!/usr/bin/env python3
"""Reserve distributed build numbers in GitHub, then archive the current checkout."""
import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRANCH = 'build-registry'
FILE = 'builds.json'


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


class APIError(RuntimeError):
    def __init__(self, result):
        super().__init__(result.stderr.strip() or result.stdout.strip())
        self.conflict = '(HTTP 409)' in result.stderr or '(HTTP 422)' in result.stderr


def api(repo, endpoint, method='GET', payload=None):
    args = ['gh', 'api', f'repos/{repo}/{endpoint}', '--method', method]
    if payload is not None:
        args += ['--input', '-']
    result = subprocess.run(args, input=json.dumps(payload) if payload is not None else None,
                            capture_output=True, text=True, cwd=ROOT)
    if result.returncode:
        raise APIError(result)
    return json.loads(result.stdout)


def now():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


class Registry:
    def __init__(self, repo):
        self.repo = repo

    def read(self):
        result = api(self.repo, f'contents/{FILE}?ref={BRANCH}')
        data = json.loads(base64.b64decode(result['content']))
        if data.get('schema') != 1:
            raise RuntimeError('Unsupported build registry schema')
        return data, result['sha']

    def initialize(self, version, build, note):
        data = {'schema': 1, 'builds': [{'build': build, 'version': version, 'status': 'reported',
                                      'created_at': now(), 'note': note}]}
        tree = api(self.repo, 'git/trees', 'POST', {'tree': [
            {'path': FILE, 'mode': '100644', 'type': 'blob', 'content': json.dumps(data, indent=2) + '\n'}]})
        commit = api(self.repo, 'git/commits', 'POST', {
            'message': f'build: record existing {version} ({build})', 'tree': tree['sha'], 'parents': []})
        # Creating a ref fails if another machine has initialized it first.
        api(self.repo, 'git/refs', 'POST', {'ref': f'refs/heads/{BRANCH}', 'sha': commit['sha']})

    def update(self, message, change):
        for _ in range(12):
            data, sha = self.read()
            value = change(data['builds'])
            content = base64.b64encode((json.dumps(data, indent=2) + '\n').encode()).decode()
            try:
                api(self.repo, f'contents/{FILE}', 'PUT', {
                    'branch': BRANCH, 'sha': sha, 'message': message, 'content': content})
                return value
            except APIError as error:
                if not error.conflict:
                    raise
                # A concurrent writer won. Read its number before trying again.
        raise RuntimeError('Build registry stayed busy; no build was started')

    def reserve(self, version, source, expected=None):
        def change(builds):
            number = max(item['build'] for item in builds) + 1
            if expected is not None and number != expected:
                raise RuntimeError(f'Next available build is {number}, not {expected}')
            record = dict(source, build=number, version=version, status='reserved', created_at=now())
            builds.append(record)
            return record
        return self.update(f'build: reserve {version}', change)

    def finish(self, record):
        def change(builds):
            existing = next(item for item in builds if item['build'] == record['build'])
            if existing['source_digest'] != record['source_digest'] or existing['status'] != 'reserved':
                raise RuntimeError('Build reservation has changed; refusing to overwrite it')
            existing.update(record)
        self.update(f'build: {record["build"]} {record["status"]}', change)


def source_state():
    digest = hashlib.sha256()
    paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT)
    for name in sorted(set(paths.split(b'\0')) - {b''}):
        path = ROOT / os.fsdecode(name)
        digest.update(name + b'\0')
        if path.is_symlink():
            digest.update(b'link\0' + os.fsencode(os.readlink(path)))
        elif path.is_file():
            digest.update(b'file\0' + path.read_bytes())
        else:
            digest.update(b'deleted\0')
        digest.update(b'\0')
    return {'source_revision': command('git', 'rev-parse', 'HEAD'),
            'branch': command('git', 'rev-parse', '--abbrev-ref', 'HEAD'),
            'uncommitted_changes': bool(command('git', 'status', '--porcelain')),
            'source_digest': digest.hexdigest()}


def version_default():
    config = (ROOT / 'Version.xcconfig').read_text()
    return re.search(r'^MARKETING_VERSION\s*=\s*(\S+)', config, re.MULTILINE)[1]


def write_record(path, record):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(record, indent=2) + '\n')
    temporary.replace(path)


def logged(args, path):
    print(f'Running xcodebuild; log: {path.relative_to(ROOT)}', flush=True)
    with path.open('w') as log:
        result = subprocess.run(['xcodebuild', *args], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'xcodebuild failed; see {path}')


def package(args, registry, repo):
    command('xcodebuild', '-version')
    version = args.version or version_default()
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise RuntimeError('Use a version such as 0.6.1')
    source = source_state()
    record = registry.reserve(version, source, args.expect_build)
    number = record['build']
    directory = ROOT / 'build' / 'releases' / str(number)
    directory.mkdir(parents=True, exist_ok=False)
    record.update(repository=repo)
    record_path = directory / 'build.json'
    write_record(record_path, record)
    print(f'Reserved {version} ({number}) from {source["source_revision"][:7]}', flush=True)
    try:
        archive = directory / 'Mailern.xcarchive'
        export = directory / 'export'
        options = directory / 'ExportOptions.plist'
        options.write_bytes(plistlib.dumps({'method': 'debugging', 'teamID': args.team_id,
                                           'signingStyle': 'automatic'}))
        logged(['-project', 'Mailern.xcodeproj', '-scheme', 'Mailern', '-configuration', 'Release',
                '-destination', 'generic/platform=iOS', '-archivePath', str(archive),
                '-derivedDataPath', str(directory / 'DerivedData'),
                f'DEVELOPMENT_TEAM={args.team_id}', f'PRODUCT_BUNDLE_IDENTIFIER={args.bundle_id}',
                f'MARKETING_VERSION={version}', f'CURRENT_PROJECT_VERSION={number}',
                '-allowProvisioningUpdates', 'archive'], directory / 'archive.log')
        if source_state() != source:
            raise RuntimeError('Source changed during archive; build number remains used. Build in an isolated worktree.')
        logged(['-exportArchive', '-archivePath', str(archive), '-exportPath', str(export),
                '-exportOptionsPlist', str(options)], directory / 'export.log')
        info = plistlib.loads((archive / 'Products/Applications/Mailern.app/Info.plist').read_bytes())
        if (info['CFBundleShortVersionString'], info['CFBundleVersion']) != (version, str(number)):
            raise RuntimeError('Archive does not match the reserved version and build')
        ipa = export / 'Mailern.ipa'
        record.update(status='exported', finished_at=now(), bundle_id=info['CFBundleIdentifier'],
                      ipa_sha256=hashlib.sha256(ipa.read_bytes()).hexdigest())
    except BaseException:
        record.update(status='failed', finished_at=now())
        write_record(record_path, record)
        registry.finish(record)
        raise
    write_record(record_path, record)
    registry.finish(record)
    print(f'Exported {version} ({number}); record: {record_path.relative_to(ROOT)}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', help='GitHub OWNER/REPO; defaults to this checkout\'s repository')
    sub = parser.add_subparsers(dest='action', required=True)
    init = sub.add_parser('init', help='Create the registry once, using the last known build')
    init.add_argument('--last-build', type=int, required=True)
    init.add_argument('--version', required=True)
    init.add_argument('--note', required=True)
    sub.add_parser('list', help='Read shared build history')
    build = sub.add_parser('package', help='Reserve a number, archive, and export')
    build.add_argument('team_id')
    build.add_argument('bundle_id', nargs='?', default='com.example.mailern')
    build.add_argument('--version', help='Defaults to Version.xcconfig in this checkout')
    build.add_argument('--expect-build', type=int, help='Fail before building if the next number differs')
    args = parser.parse_args()
    repo = args.repo or command('gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner')
    registry = Registry(repo)
    if args.action == 'init':
        registry.initialize(args.version, args.last_build, args.note)
    elif args.action == 'list':
        data, _ = registry.read()
        print('BUILD  VERSION  STATUS    SOURCE   BRANCH')
        for item in reversed(data['builds']):
            source = item.get('source_revision', 'unknown')[:7]
            dirty = '*' if item.get('uncommitted_changes') else ''
            print(f'{item["build"]:<6} {item["version"]:<8} {item["status"]:<9} {source}{dirty}  {item.get("branch", "unknown")}')
    else:
        package(args, registry, repo)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        sys.exit(str(error))
