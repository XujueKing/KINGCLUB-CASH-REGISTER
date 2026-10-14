"""Upload the verified APK first, then atomically publish stable.json on an existing static route."""
import argparse
import hashlib
import json
import re
import shlex
import subprocess
from pathlib import Path
from urllib.parse import urlsplit


def publish(directory, ssh_host):
    manifest_file = directory / 'stable.json'
    manifest = json.loads(manifest_file.read_text(encoding='utf-8'))
    filename = urlsplit(manifest['url']).path.rsplit('/', 1)[-1]
    if not re.fullmatch(r'cashier-\d+-[a-f0-9]{16}\.apk', filename):
        raise ValueError('Invalid immutable release filename')
    apk = directory / filename
    with apk.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    if digest != manifest['sha256'] or apk.stat().st_size != manifest['bytes']:
        raise ValueError('Prepared package changed; prepare it again')
    stage = subprocess.check_output(['ssh', ssh_host, 'mktemp -d /tmp/kingclub-cashier-release.XXXXXXXX'], text=True).strip()
    if not re.fullmatch(r'/tmp/kingclub-cashier-release\.[a-zA-Z0-9]+', stage):
        raise ValueError('Unexpected remote staging directory')
    subprocess.run(['scp', str(apk), str(manifest_file), f'{ssh_host}:{stage}/'], check=True)
    # Paths below are confined to this product's public release folder. No application/database restart.
    script = f'''set -eu
stage={shlex.quote(stage)}
release=/var/www/kingclub-updates/cashier
exec 9>/tmp/kingclub-cashier-publish.lock
flock 9
echo '{digest}  '$stage'/{filename}' | sha256sum -c -
sudo mkdir -p "$release"
if [ -f "$release/{filename}" ]; then
  echo '{digest}  '$release'/{filename}' | sha256sum -c -
else
  sudo install -m 644 "$stage/{filename}" "$release/{filename}.upload"
  sudo mv "$release/{filename}.upload" "$release/{filename}"
fi
if [ -f "$release/stable.json" ]; then
  python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); assert a["versionCode"] > b["versionCode"], "Version must increase"' "$stage/stable.json" "$release/stable.json"
  sudo cp "$release/stable.json" "$release/stable.previous.json"
fi
sudo install -m 644 "$stage/stable.json" "$release/stable.json.next"
sudo mv "$release/stable.json.next" "$release/stable.json"
sudo ln -sfn '{filename}' "$release/latest.apk.next"
sudo mv -Tf "$release/latest.apk.next" "$release/latest.apk"
rm "$stage/{filename}" "$stage/stable.json"
rmdir "$stage"
echo 'Cashier release published atomically'
'''
    subprocess.run(['ssh', ssh_host, 'sh', '-s'], input=script.encode('utf-8'), check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--ssh-host', required=True)
    args = parser.parse_args()
    publish(args.directory, args.ssh_host)
