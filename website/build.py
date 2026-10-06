#!/usr/bin/env python3
"""Build the static site and verify the installer before offering a download."""
import argparse
import hashlib
import json
import shutil
from html.parser import HTMLParser
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ASSETS = {
    'logo.png': 'Resources/Branding/SailKing-AppIcon.png',
    'candidate.png': 'Resources/Branding/SailKing-Candidate-Preview.png',
    'workspace.png': 'docs/images/workspace.png',
    'phrases.png': 'docs/images/phrases.png',
    'windows-workspace-preview.png': 'docs/images/windows-workspace-preview.png',
    'wechat-coffee.png': 'docs/images/wechat-coffee.png',
    'wechat-contact.png': 'docs/images/wechat-contact.png',
}


class References(HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths = set()
        self.anchors = set()
        self.ids = set()

    def handle_starttag(self, tag, attributes):
        values = dict(attributes)
        if 'id' in values:
            if values['id'] in self.ids:
                raise ValueError('Duplicate HTML id: ' + values['id'])
            self.ids.add(values['id'])
        for name in ['href', 'src', 'data-image']:
            value = values.get(name, '')
            if value.startswith('#') and len(value) > 1:
                self.anchors.add(value[1:])
            elif value and not value.startswith(('https://', 'http://', '#')):
                self.paths.add(value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--installer', required=True, type=Path)
    parser.add_argument('--output', default=ROOT / 'build/website', type=Path)
    args = parser.parse_args()
    release = json.loads((HERE / 'release.json').read_text())
    win = release['windows']
    installer = args.installer.resolve()
    if installer.name != win['file'] or installer.stat().st_size != win['size']:
        raise ValueError('Installer name or size does not match release.json')
    with installer.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    if digest != win['sha256']:
        raise ValueError('Installer SHA-256 does not match release.json')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / 'assets').mkdir(exist_ok=True)
    (output / 'downloads').mkdir(exist_ok=True)
    for name in ['index.html', 'styles.css', 'app.js', 'release.json']:
        shutil.copyfile(HERE / name, output / name)
    for name, source in ASSETS.items():
        shutil.copyfile(ROOT / source, output / 'assets' / name)
    shutil.copyfile(installer, output / 'downloads' / installer.name)
    (output / 'downloads/SHA256SUMS.txt').write_text(f"{digest}  {win['file']}\n")
    url = release['site_url']
    (output / 'robots.txt').write_text(f'User-agent: *\nAllow: /\nSitemap: {url}sitemap.xml\n')
    (output / 'sitemap.xml').write_text('<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>{url}</loc></url></urlset>\n')
    html = (output / 'index.html').read_text()
    for value in [win['version'], win['sha256'], win['file'], url]:
        if value not in html:
            raise ValueError('Landing page does not match release.json: ' + value)
    refs = References()
    refs.feed(html)
    for relative in refs.paths:
        target = (output / relative).resolve()
        if not target.is_relative_to(output) or not target.is_file():
            raise ValueError('Missing or unsafe local reference: ' + relative)
    if refs.anchors - refs.ids:
        raise ValueError('Missing anchors: ' + str(refs.anchors - refs.ids))
    print(f'Built {output}; verified {installer.name}, {win["size"]} bytes, SHA-256 {digest}')


if __name__ == '__main__':
    main()
