#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
python3 - <<'PY'
import concurrent.futures, hashlib, json, os, pathlib, subprocess, tarfile, urllib.request

vendor = pathlib.Path('Vendor')
downloads = vendor / 'downloads'
data_dir = vendor / 'RimeData'
downloads.mkdir(parents=True, exist_ok=True)
data_dir.mkdir(parents=True, exist_ok=True)
manifest = json.loads((vendor / 'rime-manifest.json').read_text())

def fetch(asset):
    path = downloads / asset['name']
    if not path.exists():
        print('Downloading', asset['name'], flush=True)
        temporary = path.with_suffix(path.suffix + '.partial')
        urllib.request.urlretrieve(asset['url'], temporary)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != asset['sha256']:
            raise RuntimeError('Checksum mismatch: ' + asset['name'])
        temporary.replace(path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != asset['sha256']:
        raise RuntimeError('Checksum mismatch: ' + asset['name'])
    return path

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    archives = list(pool.map(fetch, manifest['assets']))

def write_member(archive, member, target, executable=False):
    target.parent.mkdir(parents=True, exist_ok=True)
    content = archive.extractfile(member).read()
    # Preserve mtimes when content hasn't changed, keeping Rime's deployment incremental.
    if not target.exists() or target.read_bytes() != content:
        target.write_bytes(content)
    if executable:
        target.chmod(0o755)

for path in archives:
    with tarfile.open(path) as archive:
        if path.name.startswith('rime-33e7814-'):
            for member in archive.getmembers():
                if not member.isfile():
                    continue
                name = member.name
                if name.startswith('dist/include/') or name in ('dist/lib/librime.1.17.0.dylib', 'dist/bin/rime_deployer', 'version-info.txt'):
                    write_member(archive, member, vendor / 'librime' / name, name.startswith('dist/bin/'))
        elif path.name.startswith('rime-deps-'):
            for member in archive.getmembers():
                if member.isfile() and member.name.startswith('share/opencc/'):
                    write_member(archive, member, data_dir / 'opencc' / pathlib.Path(member.name).name)
        else:
            repo = path.name.rsplit('-', 1)[0]
            root = archive.getmembers()[0].name.split('/')[0]
            for member in archive.getmembers():
                rel = member.name[len(root) + 1:]
                if not member.isfile() or not rel or '/' in rel:
                    continue
                if rel.endswith(('.yaml', '.txt')) and not rel.startswith(('LICENSE', 'COPYING')):
                    write_member(archive, member, data_dir / rel)
                if rel.startswith(('LICENSE', 'COPYING', 'README')):
                    write_member(archive, member, vendor / 'licenses' / repo / rel)

library_dir = vendor / 'librime/dist/lib'
for name in ('librime.1.dylib', 'librime.dylib'):
    link = library_dir / name
    if not link.exists():
        link.symlink_to('librime.1.17.0.dylib')

for license in json.loads((vendor / 'license-sources.json').read_text()):
    path = vendor / 'licenses' / license['name']
    if not path.exists():
        urllib.request.urlretrieve(license['url'], path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != license['sha256']:
        raise RuntimeError('License checksum mismatch: ' + license['name'])

environment = dict(os.environ)
environment['DYLD_LIBRARY_PATH'] = str(library_dir.resolve())
with (vendor / 'rime-deploy.log').open('w') as log:
    subprocess.run([str((vendor / 'librime/dist/bin/rime_deployer').resolve()), '--build', str(data_dir.resolve())],
                   env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
print('Rime 1.17.0 and pinned Pinyin data are ready in Vendor/.')
PY
