#!/usr/bin/env python3
"""Prepare only public installation artifacts; does not start a server."""
import argparse
import html
import hashlib
import json
import plistlib
import shutil
import zipfile
from pathlib import Path
from urllib.parse import quote, urlsplit

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('base_url', help='HTTPS URL where the installation files will be served')
parser.add_argument('output', nargs='?', type=Path, default=Path('build/install'))
parser.add_argument('--build-record', type=Path, required=True, help='build/releases/NUMBER/build.json from package-demo.sh')
args = parser.parse_args()
base = args.base_url.rstrip('/')
url = urlsplit(base)
if url.scheme != 'https' or not url.hostname or url.query or url.fragment or url.username or url.password:
    parser.error('An HTTPS base URL without credentials, query, or fragment is required')
record = json.loads(args.build_record.read_text())
if record['status'] != 'exported':
    parser.error('Only successfully exported builds can be published')
directory = args.build_record.resolve().parent
archive = directory / 'Mailern.xcarchive'
ipa = directory / 'export/Mailern.ipa'
if hashlib.sha256(ipa.read_bytes()).hexdigest() != record['ipa_sha256']:
    parser.error('IPA checksum does not match its build record')

with (archive / 'Products/Applications/Mailern.app/Info.plist').open('rb') as f:
    info = plistlib.load(f)
name = info.get('CFBundleDisplayName') or info['CFBundleName']
version = info['CFBundleShortVersionString']
build = info['CFBundleVersion']
# Check the exported package as well so an old IPA cannot be paired with a newer archive.
with zipfile.ZipFile(ipa) as package:
    exported = plistlib.loads(package.read('Payload/Mailern.app/Info.plist'))
for key in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion'):
    if exported[key] != info[key]:
        parser.error(f'IPA and archive disagree on {key}')
if (version, build, info['CFBundleIdentifier']) != (record['version'], str(record['build']), record['bundle_id']):
    parser.error('Build record does not match the archive')

out = args.output
out.mkdir(parents=True, exist_ok=True)
package_name = f'Mailern-{build}.ipa'
manifest_name = f'manifest-{build}.plist'
# Each publish replaces the previous one, so the folder only serves the current build.
for pattern, current in (('Mailern-*.ipa', package_name), ('manifest-*.plist', manifest_name),
                         ('build-*.json', f'build-{build}.json')):
    for stale in out.glob(pattern):
        if stale.name != current:
            stale.unlink()
package_temp = out / (package_name + '.tmp')
if (out / package_name).exists() and hashlib.sha256((out / package_name).read_bytes()).hexdigest() != record['ipa_sha256']:
    parser.error(f'{package_name} already exists with different content')
shutil.copyfile(ipa, package_temp)
package_temp.replace(out / package_name)
manifest = {'items': [{'assets': [{'kind': 'software-package', 'url': base+'/'+quote(package_name)}], 'metadata': {'bundle-identifier': info['CFBundleIdentifier'], 'bundle-version': build, 'kind': 'software', 'title': name}}]}
manifest_temp = out / (manifest_name + '.tmp')
with manifest_temp.open('wb') as f:
    plistlib.dump(manifest, f)
manifest_temp.replace(out / manifest_name)
install = 'itms-services://?action=download-manifest&url='+quote(base+'/'+quote(manifest_name), safe='')
source = record['source_revision'][:7].lower()
if record['uncommitted_changes']:
    source += ' · Includes uncommitted changes'
page_temp = out / 'index.html.tmp'
page_temp.write_text(f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>{html.escape(name)}</title>
<style>
:root {{ color-scheme: light dark; }}
body {{ font:18px/1.6 system-ui,sans-serif; max-width:34rem; margin:0 auto; padding:64px 24px; background:Canvas; color:CanvasText; overflow-wrap:anywhere; }}
h1 {{ font-size:2rem; line-height:1.2; margin:0 0 24px; }}
p {{ margin:0 0 28px; }}
a {{ color:LinkText; text-decoration:underline; text-underline-offset:3px; }}
a:visited {{ color:VisitedText; }}
</style>
</head>
<body>
<h1>{html.escape(name)}</h1>
<p>{html.escape(version)} · Build {html.escape(build)}</p>
<p><a href="{html.escape(install, quote=True)}">Install update</a></p>
<p>Source {html.escape(source)}</p>
</body>
</html>
''', encoding='utf-8')
page_temp.replace(out / 'index.html')
write_record = out / f'build-{build}.json'
write_record.write_text(json.dumps(record, indent=2) + '\n')
print(base+'/')
