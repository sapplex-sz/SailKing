#!/usr/bin/env python3
"""Run with sudo on the Oracle host; only changes this site's routing and files."""
import argparse
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
from datetime import datetime, timezone
from pathlib import Path

DOMAIN = 'sailking.157-137-190-198.sslip.io'
SITE = Path('/var/www/sailking')
BEGIN = '# BEGIN SAILKING STATIC SITE'
END = '# END SAILKING STATIC SITE'


def run(*args):
    subprocess.run(args, check=True)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def replace_config(path, data):
    temporary = path.with_name(path.name + '.sailking-new')
    stat = path.stat()
    temporary.write_bytes(data)
    os.chown(temporary, stat.st_uid, stat.st_gid)
    os.chmod(temporary, stat.st_mode & 0o777)
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--upload', required=True, type=Path)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError('Activation requires sudo')
    upload = args.upload.resolve()
    manifest = json.loads((upload / 'release.json').read_text())
    if manifest['site_url'] != f'https://{DOMAIN}/':
        raise ValueError('Unexpected hostname')
    win = manifest['windows']
    if Path(win['file']).name != win['file']:
        raise ValueError('Invalid installer filename')
    source = upload / win['file']
    target = SITE / 'downloads' / win['file']
    installer = source if source.exists() else target
    if installer.stat().st_size != win['size'] or digest(installer) != win['sha256']:
        raise ValueError('Installer verification failed')
    if target.exists() and digest(target) != win['sha256']:
        raise ValueError('An immutable installer with different contents already exists')
    caddy = Path('/etc/caddy/Caddyfile')
    haproxy = Path('/etc/haproxy/haproxy.cfg')
    caddy_before = caddy.read_bytes()
    haproxy_before = haproxy.read_bytes()
    text = caddy_before.decode()
    fragment = (upload / 'Caddyfile.site').read_text().rstrip()
    block = f'{BEGIN}\n{fragment}\n{END}\n'
    if BEGIN in text:
        start, end = text.index(BEGIN), text.index(END) + len(END)
        text = text[:start] + block.rstrip() + text[end:]
    elif DOMAIN in text:
        raise ValueError('Hostname exists outside the SailKing managed block')
    else:
        text = text.rstrip() + '\n\n' + block
    route = f' use_backend subscription if {{ req.ssl_sni -i {DOMAIN} }}'
    proxy_text = haproxy_before.decode()
    if route not in proxy_text:
        anchor = ' default_backend reality'
        if proxy_text.count(anchor) != 1:
            raise ValueError('Unexpected HAProxy layout')
        proxy_text = proxy_text.replace(anchor, route + '\n' + anchor)
    caddy_after, haproxy_after = text.encode(), proxy_text.encode()
    stamp = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-%f')
    backup = Path('/root/sailking-site-backups') / stamp
    backup.mkdir(parents=True, mode=0o700)
    os.chmod(backup.parent, 0o700)
    shutil.copy2(caddy, backup / 'Caddyfile')
    shutil.copy2(haproxy, backup / 'haproxy.cfg')
    (backup / 'Caddyfile.new').write_bytes(caddy_after)
    (backup / 'haproxy.cfg.new').write_bytes(haproxy_after)
    previous = os.readlink(SITE / 'current') if (SITE / 'current').is_symlink() else None
    (backup / 'previous-site.json').write_text(json.dumps({'current': previous}))
    run('caddy', 'validate', '--config', str(backup / 'Caddyfile.new'), '--adapter', 'caddyfile')
    run('haproxy', '-c', '-f', str(backup / 'haproxy.cfg.new'))
    if caddy.read_bytes() != caddy_before or haproxy.read_bytes() != haproxy_before:
        raise ValueError('Server configuration changed during validation; retry after inspection')
    release = SITE / 'releases' / stamp
    release.mkdir(parents=True, mode=0o755)
    with tarfile.open(upload / 'site.tar.gz') as archive:
        for member in archive.getmembers():
            relative = Path(member.name)
            if relative.is_absolute() or '..' in relative.parts or not member.isfile():
                raise ValueError('Invalid static archive member')
            destination = release / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as stream:
                destination.write_bytes(stream.read())
            os.chmod(destination, 0o644)
    if not (release / 'index.html').is_file():
        raise ValueError('Static site is missing index.html')
    (SITE / 'downloads').mkdir(exist_ok=True, mode=0o755)
    if not target.exists():
        pending_installer = target.with_name('.' + target.name + '.new')
        shutil.copyfile(installer, pending_installer)
        if digest(pending_installer) != win['sha256']:
            raise ValueError('Installer copy verification failed')
        os.chmod(pending_installer, 0o644)
        pending_installer.replace(target)
    checksums = SITE / 'downloads/SHA256SUMS.txt'
    # Include retained versioned installers so older links remain valid.
    values = [f'{digest(file)}  {file.name}\n' for file in sorted(checksums.parent.glob('*.exe'))]
    (checksums.parent / '.SHA256SUMS.new').write_text(''.join(values))
    (checksums.parent / '.SHA256SUMS.new').replace(checksums)
    pending = SITE / '.current-new'
    if pending.is_symlink():
        pending.unlink()
    pending.symlink_to(release.relative_to(SITE))
    pending.replace(SITE / 'current')
    try:
        replace_config(caddy, caddy_after)
        replace_config(haproxy, haproxy_after)
        if haproxy_after != haproxy_before:
            run('systemctl', 'reload', 'haproxy')
        if caddy_after != caddy_before:
            run('systemctl', 'reload', 'caddy')
        run('systemctl', 'is-active', 'caddy', 'haproxy')
    except Exception:
        replace_config(caddy, caddy_before)
        replace_config(haproxy, haproxy_before)
        if previous:
            pending.symlink_to(previous)
            pending.replace(SITE / 'current')
        else:
            (SITE / 'current').unlink()
        run('systemctl', 'reload', 'haproxy')
        run('systemctl', 'reload', 'caddy')
        raise
    print(json.dumps({'site': manifest['site_url'], 'release': str(release), 'backup': str(backup), 'installer_sha256': win['sha256']}))


if __name__ == '__main__':
    with Path('/run/lock/sailking-deploy.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        main()
