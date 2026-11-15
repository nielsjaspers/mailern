#!/usr/bin/env python3
"""Prepare only public installation artifacts; does not start a server."""
import html
import plistlib
import shutil
import sys
from pathlib import Path
from urllib.parse import quote

base = sys.argv[1].rstrip('/')
if not base.startswith('https://'):
    raise SystemExit('An HTTPS base URL is required')
out = Path('build/install')
out.mkdir(parents=True, exist_ok=True)
shutil.copyfile('build/export/Mailern.ipa', out / 'Mailern.ipa')
with open('build/Mailern.xcarchive/Products/Applications/Mailern.app/Info.plist', 'rb') as f:
    info = plistlib.load(f)
manifest = {'items': [{'assets': [{'kind':'software-package','url':base+'/Mailern.ipa'}], 'metadata': {'bundle-identifier':info['CFBundleIdentifier'], 'bundle-version':info['CFBundleVersion'], 'kind':'software', 'title':'Mailern'}}]}
with (out / 'manifest.plist').open('wb') as f:
    plistlib.dump(manifest, f)
install = 'itms-services://?action=download-manifest&url='+quote(base+'/manifest.plist', safe='')
(out / 'index.html').write_text(f'''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Install Mailern</title>
<style>body{{font:18px system-ui;max-width:36rem;margin:12vh auto;padding:24px;background:#f4f7f6;color:#162c2b}}a{{display:inline-block;background:#096f6e;color:white;padding:16px 24px;border-radius:14px;text-decoration:none}}p{{line-height:1.6}}</style>
<h1>Mailern</h1><p>Version {html.escape(info["CFBundleShortVersionString"])} · Build {html.escape(info["CFBundleVersion"])}</p><p>Native iOS email workflow prototype. Fictional mail, local state.</p><a href="{html.escape(install)}">Install on iPhone</a>
<p>Open in Safari with Tailscale connected. This development build requires an iPhone registered in the signing profile and Developer Mode enabled in Settings → Privacy &amp; Security.</p>
<p>If iOS asks you to trust the developer, open Settings → General → VPN &amp; Device Management. Return to the Home Screen after accepting the install prompt.</p>
<p>In the app, use More → Drafts to reopen saved messages, Demo to simulate replies, and Settings to adjust snooze times and Labs.</p></html>''')
print(base+'/')
