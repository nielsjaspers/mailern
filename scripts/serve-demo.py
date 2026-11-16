#!/usr/bin/env python3
"""Prepare only public installation artifacts; does not start a server."""
import argparse
import html
import plistlib
import shutil
import zipfile
from pathlib import Path
from urllib.parse import quote, urlsplit

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('base_url', help='HTTPS URL where the installation files will be served')
parser.add_argument('output', nargs='?', type=Path, default=Path('build/install'))
parser.add_argument('--archive', type=Path, default=Path('build/Mailern.xcarchive'))
parser.add_argument('--ipa', type=Path, default=Path('build/export/Mailern.ipa'))
parser.add_argument('--source-revision', required=True, help='Git revision captured when this build was made')
parser.add_argument('--uncommitted-changes', action='store_true', help='The build includes uncommitted source changes')
args = parser.parse_args()
base = args.base_url.rstrip('/')
url = urlsplit(base)
if url.scheme != 'https' or not url.hostname or url.query or url.fragment or url.username or url.password:
    parser.error('An HTTPS base URL without credentials, query, or fragment is required')
if not (7 <= len(args.source_revision) <= 40) or any(c not in '0123456789abcdefABCDEF' for c in args.source_revision):
    parser.error('--source-revision must be a Git commit hash of 7 to 40 hexadecimal characters')

with (args.archive / 'Products/Applications/Mailern.app/Info.plist').open('rb') as f:
    info = plistlib.load(f)
name = info.get('CFBundleDisplayName') or info['CFBundleName']
version = info['CFBundleShortVersionString']
build = info['CFBundleVersion']
# Check the exported package as well so an old IPA cannot be paired with a newer archive.
with zipfile.ZipFile(args.ipa) as package:
    exported = plistlib.loads(package.read('Payload/Mailern.app/Info.plist'))
for key in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion'):
    if exported[key] != info[key]:
        parser.error(f'IPA and archive disagree on {key}')

out = args.output
out.mkdir(parents=True, exist_ok=True)
package_name = f'Mailern-{build}.ipa'
manifest_name = f'manifest-{build}.plist'
package_temp = out / (package_name + '.tmp')
shutil.copyfile(args.ipa, package_temp)
package_temp.replace(out / package_name)
manifest = {'items': [{'assets': [{'kind': 'software-package', 'url': base+'/'+quote(package_name)}], 'metadata': {'bundle-identifier': info['CFBundleIdentifier'], 'bundle-version': build, 'kind': 'software', 'title': name}}]}
manifest_temp = out / (manifest_name + '.tmp')
with manifest_temp.open('wb') as f:
    plistlib.dump(manifest, f)
manifest_temp.replace(out / manifest_name)
install = 'itms-services://?action=download-manifest&url='+quote(base+'/'+quote(manifest_name), safe='')
source = args.source_revision[:7].lower()
if args.uncommitted_changes:
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
print(base+'/')
