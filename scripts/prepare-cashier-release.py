"""Prepare a verified, immutable signed APK + bounded public manifest. No credentials."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path
from urllib.parse import urlsplit

PACKAGE = 'cn.kingclub.cashregister.preview'
CERTIFICATE = '7f839333dcc272a167a129317160c2a82b25b5ba8479529eac802be97c9c93ea'


def prepare(apk, output, base_url, apksigner, aapt, notes, previous=None):
    url = urlsplit(base_url)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ValueError('Release base URL must be HTTPS without credentials/query/fragment')
    if not url.path.endswith('/kingclub-updates/cashier'):
        raise ValueError('Use the cashier-only release directory')
    signature = subprocess.check_output([apksigner, 'verify', '--print-certs', str(apk)], text=True, encoding='utf-8')
    certificates = re.findall(r'Signer #\d+ certificate SHA-256 digest: ([a-fA-F0-9]+)', signature)
    if [c.lower() for c in certificates] != [CERTIFICATE]:
        raise ValueError('The APK does not use the installed cashier certificate')
    badging = subprocess.check_output([aapt, 'dump', 'badging', str(apk)], text=True, encoding='utf-8')
    identity = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
    if not identity or identity[1] != PACKAGE:
        raise ValueError('Wrong package identity')
    if not re.search(r"native-code: 'armeabi-v7a'\s*$", badging, re.M):
        raise ValueError('Expected the cashier ARM32 APK')
    code = int(identity[2])  # Read the final APK: split-per-ABI adds a version-code offset.
    if previous and code <= json.loads(Path(previous).read_text(encoding='utf-8'))['versionCode']:
        raise ValueError('Version code must be greater than the published release')
    size = apk.stat().st_size
    if not 0 < size <= 100 * 1024 * 1024:
        raise ValueError('APK exceeds client download bound')
    with apk.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    filename = f'cashier-{code}-{digest[:16]}.apk'
    output.mkdir(parents=True, exist_ok=True)
    destination = output / filename
    if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
        raise ValueError('Immutable release path already has different content')
    if not destination.exists():
        shutil.copyfile(apk, destination)
    manifest = dict(schemaVersion=1, packageName=PACKAGE, abi='armeabi-v7a',
                    versionCode=code, versionName=identity[3], bytes=size, sha256=digest,
                    url=base_url + '/' + filename, notes=notes[:1200])
    encoded = json.dumps(manifest, ensure_ascii=False, indent=2).encode('utf-8')
    if len(encoded) > 16384:
        raise ValueError('Manifest exceeds client limit')
    (output / 'stable.json').write_bytes(encoded)
    print(f'Prepared {filename}; versionCode={code}; certificate verified')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--apk', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--base-url', required=True)
    p.add_argument('--apksigner', required=True)
    p.add_argument('--aapt', required=True)
    p.add_argument('--notes', required=True)
    p.add_argument('--previous')
    a = p.parse_args()
    prepare(a.apk, a.output, a.base_url, a.apksigner, a.aapt, a.notes, a.previous)
