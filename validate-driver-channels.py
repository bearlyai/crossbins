#!/usr/bin/env python3
"""Keep legacy desktop clients on their compatible driver channel."""
import argparse
import json
import hashlib
import copy
import tempfile
import urllib.request
from pathlib import Path

LEGACY_TAG = 'cua-driver-rs-v0.28.2'
FROZEN_RELEASE = '2026-09-21'
FROZEN_HASHES = {
    "cua-driver": {
        "darwin-universal": "2b0987aad72304bb41570201e4ec11e493ee8a086dc3c36a01f1c6ee25174a44",
        "linux-x86_64": "3739101d072bdfdd83b7e70b3a16d9271f6eb124e7c5e69b3406f20f0910a4ca",
        "linux-aarch64": "7bf81867627620c72a01a6bb514cc5af650a33a94cf5122b270aa09d07ce4161",
        "windows-x86_64": "b88a09b31c89aee67719b77398e1d20ba1344f9ba0e4bdf7ef966aeb2b4895c1",
        "windows-aarch64": "c8661ce568edec00696c70043aa1e7e42b44c88ba3364369a39a64ba3eb55afd"
    },
    "cua-driver-uia": {
        "windows-x86_64": "d6bef98738adacad8ed98a7e0ce8c3557f870dda4c035b955b005d28cb309b92",
        "windows-aarch64": "b59358f0ddd8bdeecf53011aae40087eb1a1685f6cab34ac65b0a4def35c5bce"
    }
}
BEARLY_TAG = 'cua-driver-rs-v0.34.1-bearly.1'


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def validate(config, lock=None, output=None):
    tools = {tool['name']: tool for tool in config['tools']}
    for name, repo, tag in [
        ('cua-driver', 'trycua/cua', LEGACY_TAG),
        ('cua-driver-uia', 'trycua/cua', LEGACY_TAG),
        ('computer-use-driver', 'bearlyai/cua', BEARLY_TAG),
        ('computer-use-driver-uia', 'bearlyai/cua', BEARLY_TAG),
    ]:
        tool = tools[name]
        if tool.get('repo') != repo or tool.get('release_tag') != tag:
            raise ValueError(f'{name} must remain pinned to {repo}@{tag}')
        if tool.get('release_tag_pattern') or tool.get('include_prereleases'):
            raise ValueError(f'{name} cannot use automatic release discovery')
        if name in FROZEN_HASHES and tool.get('frozen_release') != FROZEN_RELEASE:
            raise ValueError(f'{name} must use signed release {FROZEN_RELEASE}')
        if lock is not None:
            matches = [entry for entry in lock['tools'] if entry['name'] == name]
            if len(matches) != 1:
                raise ValueError(f'{name} needs exactly one locked entry')
            entry = matches[0]
            if entry['tag'] != tag or entry['version'] != tag[len('cua-driver-rs-v'):]:
                raise ValueError(f'{name} lock does not match its exact pin')
            platforms = {(asset['os'], asset['arch'], asset['variant']) for asset in entry['assets']}
            expected = {('windows', 'x86_64', ''), ('windows', 'aarch64', '')}
            if not name.endswith('-uia'):
                expected |= {('darwin', 'universal', ''), ('linux', 'x86_64', ''), ('linux', 'aarch64', '')}
            if platforms != expected or len(entry['assets']) != len(expected):
                raise ValueError(f'{name} has an incomplete or unexpected platform set')
            if name in FROZEN_HASHES:
                if entry.get('frozen_release') != FROZEN_RELEASE:
                    raise ValueError('Legacy lock must name the frozen signed release')
                for asset in entry['assets']:
                    platform = f"{asset['os']}-{asset['arch']}"
                    expected_hash = FROZEN_HASHES[name][platform]
                    if asset.get('sha256') != expected_hash or asset.get('source_sha256') != expected_hash:
                        raise ValueError(f'{name} {platform} differs from the frozen signed bytes')
                    if output is not None:
                        for filename in (asset['normalized'], asset['frozen_alias']):
                            if digest(output / filename) != expected_hash:
                                raise ValueError(f'{filename} changed after freezing/signing')




def stage_frozen(name, output):
    base = f'https://github.com/bearlyai/crossbins/releases/download/{FROZEN_RELEASE}'
    with urllib.request.urlopen(f'{base}/manifest.json') as response:
        manifest = json.load(response)
    tool = next(tool for tool in manifest['tools'] if tool['name'] == name)
    actual = {asset['name']: asset['sha256'] for asset in tool['assets']}
    if tool['version'] != '0.28.2' or actual != FROZEN_HASHES[name]:
        raise ValueError('Frozen source manifest changed')
    assets = []
    output.mkdir(parents=True, exist_ok=True)
    for asset in tool['assets']:
        alias = asset['url'].rsplit('/', 1)[1]
        normalized = alias.replace(name + '-', name + '-0.28.2-', 1)
        for filename in (normalized, alias):
            destination = output / filename
            if not destination.exists() or digest(destination) != asset['sha256']:
                urllib.request.urlretrieve(f'{base}/{filename}', destination)
            if digest(destination) != asset['sha256']:
                raise ValueError(f'Frozen source asset changed: {filename}')
        assets.append({
            'upstream': normalized, 'download_url': f'{base}/{normalized}',
            'normalized': normalized, 'frozen_alias': alias,
            'os': asset['os'], 'arch': asset['arch'], 'variant': asset['variant'],
            'source_sha256': asset['sha256'], 'sha256': asset['sha256'],
        })
    return {'name': name, 'version': '0.28.2', 'tag': LEGACY_TAG, 'frozen_release': FROZEN_RELEASE, 'assets': assets}


def self_test(config):
    lock = {'tools': []}
    for name in ('cua-driver', 'cua-driver-uia', 'computer-use-driver', 'computer-use-driver-uia'):
        platforms = [('windows', 'x86_64'), ('windows', 'aarch64')]
        if not name.endswith('-uia'):
            platforms += [('darwin', 'universal'), ('linux', 'x86_64'), ('linux', 'aarch64')]
        tag = LEGACY_TAG if name in FROZEN_HASHES else BEARLY_TAG
        assets = []
        for os_name, arch in platforms:
            h = FROZEN_HASHES.get(name, {}).get(f'{os_name}-{arch}', '0' * 64)
            assets.append({'os': os_name, 'arch': arch, 'variant': '', 'sha256': h, 'source_sha256': h,
                           'normalized': f'{name}-0.28.2-{os_name}-{arch}', 'frozen_alias': f'{name}-{os_name}-{arch}'})
        lock['tools'].append({'name': name, 'version': tag[len('cua-driver-rs-v'):], 'tag': tag, 'frozen_release': FROZEN_RELEASE, 'assets': assets})
    validate(config, lock)
    def legacy(c):
        return next(tool for tool in c['tools'] if tool['name'] == 'cua-driver')

    cases = [
        ('changed legacy tag', lambda c, l: legacy(c).update(release_tag='cua-driver-rs-v0.34.1')),
        ('legacy discovery pattern', lambda c, l: legacy(c).update(release_tag_pattern='.*')),
        ('wrong legacy repo', lambda c, l: legacy(c).update(repo='other/repo')),
        ('missing legacy platform', lambda c, l: l['tools'][0]['assets'].pop()),
        ('changed legacy hash', lambda c, l: l['tools'][0]['assets'][0].update(sha256='0' * 64)),
    ]
    for label, mutate in cases:
        c, l = copy.deepcopy(config), copy.deepcopy(lock)
        mutate(c, l)
        try:
            validate(c, l)
        except ValueError:
            print(f'PASS: rejected {label}')
        else:
            raise AssertionError(f'Guard accepted {label}')

    with tempfile.TemporaryDirectory() as folder:
        output = Path(folder)
        output.joinpath(lock['tools'][0]['assets'][0]['normalized']).write_bytes(b'changed signing output')
        try:
            validate(config, lock, output)
        except ValueError:
            print('PASS: rejected changed frozen output bytes after signing')
        else:
            raise AssertionError('Guard accepted changed frozen output bytes')


    # Use the real signed baseline, so the versioned bytes stay correct while
    # only the alias that older desktops download is corrupted.
    source_output = Path(__file__).resolve().parent / 'output'
    frozen = [stage_frozen(name, source_output) for name in FROZEN_HASHES]
    alias_lock = copy.deepcopy(lock)
    for entry in frozen:
        alias_lock['tools'] = [entry if tool['name'] == entry['name'] else tool for tool in alias_lock['tools']]
    changed_alias = frozen[0]['assets'][0]['frozen_alias']
    with tempfile.TemporaryDirectory() as folder:
        output = Path(folder)
        for entry in frozen:
            for asset in entry['assets']:
                for filename in (asset['normalized'], asset['frozen_alias']):
                    if filename == changed_alias:
                        output.joinpath(filename).write_bytes(b'changed version-less signed asset')
                    else:
                        output.joinpath(filename).symlink_to((source_output / filename).resolve())
        try:
            validate(config, alias_lock, output)
        except ValueError as error:
            if changed_alias not in str(error):
                raise
            print('PASS: rejected changed version-less alias with correct versioned bytes')
        else:
            raise AssertionError('Guard accepted changed frozen alias')


def validate_manifest(manifest):
    for name, expected in FROZEN_HASHES.items():
        tool = next(tool for tool in manifest['tools'] if tool['name'] == name)
        actual = {asset['name']: asset['sha256'] for asset in tool['assets']}
        if tool['version'] != '0.28.2' or actual != expected:
            raise ValueError(f'{name} manifest differs from signed baseline')


if __name__ == '__main__':
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lock', action='store_true')
    parser.add_argument('--outputs', action='store_true')
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--stage', choices=list(FROZEN_HASHES))
    args = parser.parse_args()
    config = json.loads((root / 'binaries.json').read_text())
    if args.self_test:
        self_test(config)
    elif args.stage:
        print(json.dumps(stage_frozen(args.stage, root / 'output')))
    else:
        validate(config, json.loads((root / 'binaries.lock.json').read_text()) if args.lock else None,
                 root / 'output' if args.outputs else None)
