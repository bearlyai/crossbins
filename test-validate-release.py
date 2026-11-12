#!/usr/bin/env python3
"""Prove the release guard rejects every change it exists to stop.

Offline cases use small stand-in files: the checked-in baseline with each hash replaced by the
hash of a stand-in, so the whole release (config, lock, output files and generated manifest)
can be built and broken one way at a time. Network cases use the real signed files.
Run with --offline to skip the network cases.
"""
import copy
import hashlib
import json
import runpy
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
guard = runpy.run_path(str(ROOT / 'validate-release.py'))
build_manifest = runpy.run_path(str(ROOT / 'generate-manifest.py'))['build']
CONFIG = json.loads((ROOT / 'binaries.json').read_text())
PRODUCTION = guard['PRODUCTION_BASELINE']
NEW_CHANNELS = guard['NEW_CHANNELS']
TAG = 'self-test-1'


def stand_in(*parts):
    return ' '.join(parts).encode() * 64


def stand_in_baselines():
    baseline = copy.deepcopy(guard['load_baseline'](PRODUCTION))
    for tool in baseline['tools']:
        for asset in tool['assets']:
            asset['sha256'] = hashlib.sha256(stand_in(tool['name'], asset['name'])).hexdigest()
    return {PRODUCTION: baseline}


def tool(config, name):
    return next(entry for entry in config['tools'] if entry['name'] == name)


def release(output, config=CONFIG):
    """Stage a complete stand-in release into output and return its lock and manifest."""
    baselines = stand_in_baselines()
    frozen = guard['frozen_entries'](config, baselines)
    lock = {'release_tag': TAG, 'tools': []}
    for entry in config['tools']:
        name = entry['name']
        if name in frozen:
            locked = copy.deepcopy(frozen[name])
            for asset in locked['assets']:
                platform = asset['frozen_alias'][len(name) + 1:]
                for filename in (asset['normalized'], asset['frozen_alias']):
                    (output / filename).write_bytes(stand_in(name, platform.removesuffix('.exe').removesuffix('.tar.gz')))
        else:
            tag = NEW_CHANNELS[name][1] if name in NEW_CHANNELS else 'refreshed'
            version = tag[len('cua-driver-rs-v'):] if name in NEW_CHANNELS else '99.0'
            platforms = [('windows', 'x86_64', '.exe'), ('windows', 'aarch64', '.exe')]
            if not name.endswith('-uia'):
                platforms += [('darwin', 'universal', '.tar.gz'), ('linux', 'x86_64', ''), ('linux', 'aarch64', '')]
            assets = []
            for os_name, arch, suffix in platforms:
                normalized = f'{name}-{version}-{os_name}-{arch}{suffix}'
                (output / normalized).write_bytes(stand_in(normalized))
                assets.append({'upstream': normalized, 'download_url': 'https://example.invalid/' + normalized,
                               'normalized': normalized, 'os': os_name, 'arch': arch, 'variant': '',
                               'sha256': hashlib.sha256(stand_in(normalized)).hexdigest()})
            locked = {'name': name, 'version': version, 'tag': tag, 'assets': assets}
        lock['tools'].append(locked)
    return lock, build_manifest(lock, config, output), baselines


def expect_rejected(label, config, lock, output, manifest, baselines, needle=None):
    try:
        guard['validate'](config, lock, output, manifest, baselines)
    except ValueError as error:
        if needle and needle not in str(error):
            raise AssertionError(f'{label}: rejected for the wrong reason: {error}')
        print(f'PASS: rejected {label} ({error})')
    else:
        raise AssertionError(f'Guard accepted {label}')


def offline_cases():
    with tempfile.TemporaryDirectory() as folder:
        output = Path(folder)
        lock, manifest, baselines = release(output)
        guard['validate'](CONFIG, lock, output, manifest, baselines)
        print('PASS: accepted the baseline tools unchanged plus the new driver entries')

        def case(label, mutate, needle=None):
            config, changed_lock, changed_manifest = copy.deepcopy(CONFIG), copy.deepcopy(lock), copy.deepcopy(manifest)
            with tempfile.TemporaryDirectory() as other:
                changed_output = Path(other)
                for path in output.iterdir():
                    (changed_output / path.name).write_bytes(path.read_bytes())
                mutate(config, changed_lock, changed_output, changed_manifest)
                expect_rejected(label, config, changed_lock, changed_output, changed_manifest, baselines, needle)

        # Driver pins.
        case('changed legacy tag', lambda c, l, o, m: tool(c, 'cua-driver').update(release_tag='cua-driver-rs-v0.34.1'))
        case('legacy discovery pattern', lambda c, l, o, m: tool(c, 'cua-driver').update(release_tag_pattern='.*'))
        case('wrong legacy repo', lambda c, l, o, m: tool(c, 'cua-driver').update(repo='other/repo'))
        case('unfrozen legacy driver', lambda c, l, o, m: tool(c, 'cua-driver-uia').pop('frozen_release'))
        case('changed new driver pin', lambda c, l, o, m: tool(c, 'computer-use-driver').update(release_tag='cua-driver-rs-v0.35.0-bearly.1'))
        case('missing new driver platform', lambda c, l, o, m: entry(l['tools'], 'computer-use-driver')['assets'].pop())

        # 1. A carried-over file's bytes differ, under either name.
        rg = entry(lock['tools'], 'rg')['assets'][0]
        bun = entry(lock['tools'], 'bun')['assets'][-1]
        case('changed versioned bytes (rg)', lambda c, l, o, m: (o / rg['normalized']).write_bytes(b'rebuilt' * 300), rg['normalized'])
        case('changed version-less bytes (bun)', lambda c, l, o, m: (o / bun['frozen_alias']).write_bytes(b'rebuilt' * 300), bun['frozen_alias'])
        case('changed frozen lock hash', lambda c, l, o, m: entry(l['tools'], 'uv')['assets'][0].update(sha256='0' * 64), 'uv lock')
        case('refreshed tool in the lock', lambda c, l, o, m: entry(l['tools'], 'yt-dlp').update(version='2026.10.26'), 'yt-dlp lock')

        # 2. A baseline file is missing, or a frozen manifest entry differs from the baseline.
        ffmpeg = entry(lock['tools'], 'ffmpeg')['assets'][0]
        case('missing version-less file (ffmpeg)', lambda c, l, o, m: (o / ffmpeg['frozen_alias']).unlink(), 'missing')
        case('missing versioned file (cua-driver)', lambda c, l, o, m: (o / entry(l['tools'], 'cua-driver')['assets'][0]['normalized']).unlink(), 'missing')
        case('changed manifest version (bun)', lambda c, l, o, m: entry(m['tools'], 'bun').update(version='1.4.4'), 'bun manifest')
        case('changed manifest hash (uv)', lambda c, l, o, m: entry(m['tools'], 'uv')['assets'][2].update(sha256='1' * 64), 'uv manifest')
        case('changed manifest file name (rg)', lambda c, l, o, m: entry(m['tools'], 'rg')['assets'][0].update(url=m['download_base'] + '/rg-15.2.0-darwin-aarch64'), 'rg manifest')
        case('changed manifest variant (ffmpeg)', lambda c, l, o, m: entry(m['tools'], 'ffmpeg')['assets'][0].update(variant=''), 'ffmpeg manifest')
        case('missing manifest asset (yt-dlp)', lambda c, l, o, m: entry(m['tools'], 'yt-dlp')['assets'].pop(), 'yt-dlp manifest')
        case('extra manifest field (cua-driver)', lambda c, l, o, m: entry(m['tools'], 'cua-driver')['assets'][0].update(size=1), 'cua-driver manifest')
        case('manifest URL on the latest feed', lambda c, l, o, m: entry(m['tools'], 'rg')['assets'][0].update(url='https://github.com/bearlyai/crossbins/releases/latest/download/rg-darwin-aarch64'), 'this release')
        case('changed platform map', lambda c, l, o, m: m['platform_map']['arch'].update(arm64='arm64'), 'platform map')

        # 3. The manifest or config holds a tool other than the baseline tools plus the two new entries.
        case('extra manifest tool', lambda c, l, o, m: m['tools'].append({'name': 'node', 'version': '1', 'assets': []}), 'manifest must contain')
        case('missing manifest tool', lambda c, l, o, m: m['tools'].remove(entry(m['tools'], 'ffmpeg')), 'manifest must contain')
        case('extra configured tool', lambda c, l, o, m: c['tools'].append({'name': 'node', 'repo': 'nodejs/node'}), 'binaries.json must list')

        # A tampered baseline file is refused before anything is compared with it.
        with tempfile.TemporaryDirectory() as other:
            root = Path(other)
            (root / 'baseline').mkdir()
            source = (ROOT / 'baseline' / f'{PRODUCTION}.manifest.json').read_text()
            (root / 'baseline' / f'{PRODUCTION}.manifest.json').write_text(source.replace('"15.2.0"', '"15.2.1"'))
            try:
                guard['load_baseline'](PRODUCTION, root)
            except ValueError as error:
                print(f'PASS: rejected edited baseline file ({error})')
            else:
                raise AssertionError('Guard accepted an edited baseline file')

    # A later release refreshes a tool by removing its freeze marker; the drivers stay checked.
    config = copy.deepcopy(CONFIG)
    tool(config, 'bun').pop('frozen_release')
    with tempfile.TemporaryDirectory() as folder:
        output = Path(folder)
        lock, manifest, baselines = release(output, config)
        assert entry(manifest['tools'], 'bun')['version'] == '99.0'
        guard['validate'](config, lock, output, manifest, baselines)
        print('PASS: accepted a refreshed bun once its freeze marker is removed')


def network_cases():
    """Real signed files: the checked-in baseline is the release's own manifest, and a corrupted
    version-less file is caught while its versioned twin is intact."""
    source_output = ROOT / 'output'
    # Only the drivers are compared here, so this stages their files rather than every tool's.
    config = copy.deepcopy(CONFIG)
    for entry in config['tools']:
        if entry['name'] not in guard['LEGACY_CHANNELS']:
            entry.pop('frozen_release', None)
    frozen = [guard['stage'](CONFIG, name, source_output) for name in guard['LEGACY_CHANNELS']]
    print('PASS: checked-in baseline equals the published 2026-09-21 manifest; real driver files match it')
    changed = frozen[0]['assets'][0]['frozen_alias']
    with tempfile.TemporaryDirectory() as folder:
        output = Path(folder)
        for entry in frozen:
            for asset in entry['assets']:
                for filename in (asset['normalized'], asset['frozen_alias']):
                    (output / filename).symlink_to((source_output / filename).resolve())
        guard['validate'](config, output=output)
        (output / changed).unlink()
        (output / changed).write_bytes(b'changed version-less signed asset')
        try:
            guard['validate'](config, output=output)
        except ValueError as error:
            if changed not in str(error):
                raise
            print('PASS: rejected changed real version-less file with correct versioned bytes')
        else:
            raise AssertionError('Guard accepted changed frozen alias')


def entry(items, name):
    return next(item for item in items if item['name'] == name)


if __name__ == '__main__':
    offline_cases()
    if '--offline' not in sys.argv[1:]:
        network_cases()
    print('All release guard cases passed')
