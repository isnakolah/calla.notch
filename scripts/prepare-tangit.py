#!/usr/bin/env python3
"""Build-machine only: stage Tangit and verified native provider packages."""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tarfile

parser = argparse.ArgumentParser()
parser.add_argument('--source', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
source = args.source.resolve()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
cache = root / 'build/private/dependency-check'
cache.mkdir(parents=True, exist_ok=True)
dependencies = json.loads((root / 'Distribution/dependencies.json').read_text())

def digest(path, algorithm='sha256'):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, algorithm).hexdigest()

for name in ('codex', 'claude', 'agy'):
    dep = dependencies[name]
    filename = {'codex': f"codex-{dep['version']}.tar.gz", 'claude': f"claude-{dep['version']}", 'agy': 'agy.payload'}[name]
    archive = cache / filename
    if not archive.exists() or digest(archive, dep['algorithm']) != dep['checksum']:
        partial = archive.with_suffix(archive.suffix + '.partial')
        subprocess.run(['/usr/bin/curl', '--fail', '--location', '--proto', '=https',
                        '--proto-redir', '=https', '--retry', '3', '--output', str(partial), dep['url']], check=True)
        if digest(partial, dep['algorithm']) != dep['checksum']:
            partial.unlink()
            raise SystemExit(f'{name} checksum mismatch; refusing to package')
        partial.replace(archive)
    destination = output / 'Providers' / name
    destination.mkdir(parents=True, exist_ok=True)
    if name == 'codex':
        with tarfile.open(archive) as bundle:
            bundle.extractall(destination, filter='data')
    elif name == 'claude':
        (destination / 'bin').mkdir(exist_ok=True)
        shutil.copy2(archive, destination / 'bin/claude')
        (destination / 'bin/claude').chmod(0o755)
    else:
        (destination / 'bin').mkdir(exist_ok=True)
        with tarfile.open(archive) as bundle, bundle.extractfile('antigravity') as stream:
            with (destination / 'bin/agy').open('wb') as target:
                shutil.copyfileobj(stream, target)
        (destination / 'bin/agy').chmod(0o755)
    binary = destination / 'bin' / name
    actual = subprocess.check_output([str(binary), '--version'], text=True).strip()
    if dep['version'] not in actual:
        raise SystemExit(f'{name} version mismatch: {actual}')
    print(f'Bundled {actual}', flush=True)

# Hash the actual build inputs, including uncommitted work, for traceability.
names = subprocess.check_output(['git', '-C', str(source), 'ls-files', '-co', '--exclude-standard', '-z']).split(b'\0')
tree = hashlib.sha256()
for name in sorted(set(names)):
    if not name:
        continue
    path = source / os.fsdecode(name)
    if path.is_file() and (path.suffix == '.go' or path.name in ('go.mod', 'go.sum')):
        tree.update(name + b'\0' + path.read_bytes() + b'\0')
revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
version = '0.1.0-private+' + tree.hexdigest()[:12]
environment = dict(os.environ, GOOS='darwin', GOARCH='arm64', CGO_ENABLED='1',
                   MACOSX_DEPLOYMENT_TARGET='15.0', CGO_CFLAGS='-mmacosx-version-min=15.0',
                   CGO_LDFLAGS='-mmacosx-version-min=15.0')
subprocess.run(['go', 'build', '-trimpath', '-ldflags',
                '-s -w -X github.com/isnakolah/tangit/internal/app.distributionVersion=' + version,
                '-o', str(output / 'tangit'), './cmd/tangit'], cwd=source, env=environment, check=True)
(output / 'tangit-build.json').write_text(json.dumps(dict(version=version, sourceRevision=revision,
    sourceSHA256=tree.hexdigest(), deviceLogin=True), indent=2) + '\n')
shutil.copy2(source / 'LICENSE', output / 'Tangit-LICENSE.txt')
actual_version = subprocess.check_output([str(output / 'tangit'), 'version'], text=True).strip()
if actual_version != version:
    raise SystemExit(f'Tangit version mismatch: {actual_version}')
# Retain license notices for dependencies compiled into the Go executable.
modules = subprocess.check_output(['go', 'list', '-m', '-json', 'all'], cwd=source, text=True)
decoder = json.JSONDecoder()
notices = []
while modules.strip():
    module, end = decoder.raw_decode(modules.lstrip())
    modules = modules.lstrip()[end:]
    directory = pathlib.Path(module.get('Dir', '/nonexistent'))
    for path in sorted(directory.glob('*')):
        if path.is_file() and path.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE', 'COPYRIGHT')):
            notices.append(module['Path'] + ' ' + module.get('Version', '') + ' / ' + path.name + '\n' + path.read_text(errors='replace'))
(output / 'Go-dependency-notices.txt').write_text('\n\n'.join(notices))
# Preserve Go dependency notices alongside the executable.
subprocess.run(['go', 'version', '-m', str(output / 'tangit')], check=True)
