#!/usr/bin/env python3
"""Guard what a crossbins release may contain.

A tool marked `frozen_release` in binaries.json is carried over byte for byte from that
crossbins release. The release's own manifest, checked in as baseline/<release>.manifest.json,
is the only source of the expected names, versions, platforms and hashes: staging, the lock,
the output files and the generated manifest are all checked against it.
"""
import argparse
import copy
import hashlib
import json
import os
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CROSSBINS = 'https://github.com/bearlyai/crossbins'
# The release desktops read today, and the rollback target. A release may contain exactly
# its tools plus the new driver entries.
PRODUCTION_BASELINE = '2026-09-21'
# Accepting a release as a frozen source is a reviewed change: pin its manifest file here.
BASELINE_SHA256 = {
    '2026-09-21': '7f01948cb77b36bfce9a6da3a284f53aeca9eead065b1153ff82df69b9adb3de',
}
# Desktop 5.2.3 to 5.2.11 read only these entries, so they stay on the production baseline.
LEGACY_CHANNELS = {
    'cua-driver': ('trycua/cua', 'cua-driver-rs-v0.28.2'),
    'cua-driver-uia': ('trycua/cua', 'cua-driver-rs-v0.28.2'),
}
NEW_CHANNELS = {
    'computer-use-driver': ('bearlyai/cua', 'cua-driver-rs-v0.34.1-bearly.2'),
    'computer-use-driver-uia': ('bearlyai/cua', 'cua-driver-rs-v0.34.1-bearly.2'),
}


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def project_url(config):
    repo = os.environ.get('GITHUB_REPOSITORY')
    return f'https://github.com/{repo}' if repo else config['project_url']


def load_baseline(release, root=ROOT):
    if release not in BASELINE_SHA256:
        raise ValueError(f'{release} is not an accepted frozen release')
    path = root / 'baseline' / f'{release}.manifest.json'
    if not path.is_file():
        raise ValueError(f'baseline/{path.name} is missing')
    if digest(path) != BASELINE_SHA256[release]:
        raise ValueError(f'baseline/{path.name} differs from its pinned hash')
    return json.loads(path.read_text())


def baselines_for(config, root=ROOT):
    releases = {PRODUCTION_BASELINE} | {tool['frozen_release'] for tool in config['tools'] if tool.get('frozen_release')}
    return {release: load_baseline(release, root) for release in sorted(releases)}


def baseline_tool(baselines, release, name):
    if release not in baselines:
        raise ValueError(f'{name} names unknown frozen release {release}')
    matches = [tool for tool in baselines[release]['tools'] if tool['name'] == name]
    if len(matches) != 1:
        raise ValueError(f'{name} is not in frozen release {release}')
    return matches[0]


def frozen_lock_entry(tool, baseline_entry):
    """The lock entry of a frozen tool, derived only from its release's manifest."""
    name, version, release = tool['name'], baseline_entry['version'], tool['frozen_release']
    base = f'{CROSSBINS}/releases/download/{release}'
    assets = []
    for asset in baseline_entry['assets']:
        # Both names exist in the release: <tool>-<platform> and <tool>-<version>-<platform>.
        alias = asset['url'].rsplit('/', 1)[1]
        prefix = f"{name}-{asset['name']}"
        if not alias.startswith(prefix) or alias[len(prefix):] not in ('', '.exe', '.tar.gz'):
            raise ValueError(f'unexpected asset name {alias} in {release}')
        normalized = f'{name}-{version}-{alias[len(name) + 1:]}'
        assets.append({
            'upstream': normalized, 'download_url': f'{base}/{normalized}',
            'normalized': normalized, 'frozen_alias': alias,
            'os': asset['os'], 'arch': asset['arch'], 'variant': asset['variant'],
            'source_sha256': asset['sha256'], 'sha256': asset['sha256'],
        })
    return {'name': name, 'version': version, 'tag': tool.get('release_tag') or release,
            'frozen_release': release, 'assets': assets}


def frozen_entries(config, baselines):
    return {tool['name']: frozen_lock_entry(tool, baseline_tool(baselines, tool['frozen_release'], tool['name']))
            for tool in config['tools'] if tool.get('frozen_release')}


def allowed_tools(baselines):
    return [tool['name'] for tool in baselines[PRODUCTION_BASELINE]['tools']] + list(NEW_CHANNELS)


def validate_config(config, baselines):
    names = [tool['name'] for tool in config['tools']]
    if names != allowed_tools(baselines):
        raise ValueError(f'binaries.json must list exactly {allowed_tools(baselines)}, got {names}')
    tools = {tool['name']: tool for tool in config['tools']}
    for name, (repo, tag) in {**LEGACY_CHANNELS, **NEW_CHANNELS}.items():
        tool = tools[name]
        if tool.get('repo') != repo or tool.get('release_tag') != tag:
            raise ValueError(f'{name} must remain pinned to {repo}@{tag}')
        if tool.get('release_tag_pattern') or tool.get('include_prereleases'):
            raise ValueError(f'{name} cannot use automatic release discovery')
    for name in LEGACY_CHANNELS:
        if tools[name].get('frozen_release') != PRODUCTION_BASELINE:
            raise ValueError(f'{name} must stay frozen to {PRODUCTION_BASELINE}')


def validate_lock(config, lock, frozen):
    names = [tool['name'] for tool in config['tools']]
    if [entry['name'] for entry in lock['tools']] != names:
        raise ValueError('lock must list exactly the configured tools, in order')
    for entry in lock['tools']:
        name = entry['name']
        if name in frozen and entry != frozen[name]:
            raise ValueError(f'{name} lock differs from frozen release {frozen[name]["frozen_release"]}')
        channel = {**LEGACY_CHANNELS, **NEW_CHANNELS}.get(name)
        if channel is None:
            continue
        tag = channel[1]
        if entry['tag'] != tag or entry['version'] != tag[len('cua-driver-rs-v'):]:
            raise ValueError(f'{name} lock does not match its exact pin')
        platforms = {(asset['os'], asset['arch'], asset['variant']) for asset in entry['assets']}
        expected = {('windows', 'x86_64', ''), ('windows', 'aarch64', '')}
        if not name.endswith('-uia'):
            expected |= {('darwin', 'universal', ''), ('linux', 'x86_64', ''), ('linux', 'aarch64', '')}
        if platforms != expected or len(entry['assets']) != len(expected):
            raise ValueError(f'{name} has an incomplete or unexpected platform set')


def validate_outputs(output, frozen):
    for entry in frozen.values():
        for asset in entry['assets']:
            for filename in (asset['normalized'], asset['frozen_alias']):
                path = output / filename
                if not path.is_file():
                    raise ValueError(f'{filename} from {entry["frozen_release"]} is missing from output')
                if digest(path) != asset['sha256']:
                    raise ValueError(f'{filename} differs from the bytes in {entry["frozen_release"]}')


def validate_manifest(manifest, config, baselines):
    """A frozen tool's entry equals its release's entry; only each URL's release path differs."""
    production = baselines[PRODUCTION_BASELINE]
    if set(manifest) != set(production) or manifest['platform_map'] != production['platform_map']:
        raise ValueError('manifest fields or platform map differ from the baseline')
    base = f"{project_url(config)}/releases/download/{manifest['release_tag']}"
    if manifest['download_base'] != base:
        raise ValueError(f'manifest download_base must be {base}')
    names = [tool['name'] for tool in manifest['tools']]
    if names != allowed_tools(baselines):
        raise ValueError(f'manifest must contain exactly {allowed_tools(baselines)}, got {names}')
    sources = {tool['name']: tool.get('frozen_release') for tool in config['tools']}
    for tool in manifest['tools']:
        for asset in tool['assets']:
            if not asset['url'].startswith(base + '/'):
                raise ValueError(f"{tool['name']} {asset['name']} must download from this release")
        source = sources.get(tool['name'])
        if source:
            expected = copy.deepcopy(baseline_tool(baselines, source, tool['name']))
            for asset in expected['assets']:
                asset['url'] = f"{base}/{asset['url'].rsplit('/', 1)[1]}"
            if tool != expected:
                raise ValueError(f"{tool['name']} manifest entry differs from {source}")
        elif tool['name'] in NEW_CHANNELS:
            if tool['version'] != NEW_CHANNELS[tool['name']][1][len('cua-driver-rs-v'):]:
                raise ValueError(f"{tool['name']} manifest version differs from its pin")


def validate(config, lock=None, output=None, manifest=None, baselines=None):
    baselines = baselines_for(config) if baselines is None else baselines
    validate_config(config, baselines)
    frozen = frozen_entries(config, baselines)
    if lock is not None:
        validate_lock(config, lock, frozen)
    if output is not None:
        validate_outputs(output, frozen)
    if manifest is not None:
        validate_manifest(manifest, config, baselines)


def fetch(url, destination):
    partial = destination.with_name(destination.name + '.part')
    for attempt in range(3):
        try:
            urllib.request.urlretrieve(url, partial)
            partial.replace(destination)
            return
        except OSError:
            if attempt == 2:
                raise
            time.sleep(5 * (attempt + 1))


def stage(config, name, output):
    """Copy a frozen tool's files from its release, without touching upstream."""
    tool = next(tool for tool in config['tools'] if tool['name'] == name)
    release = tool.get('frozen_release')
    if not release:
        raise ValueError(f'{name} is not frozen')
    baselines = baselines_for(config)
    with urllib.request.urlopen(f'{CROSSBINS}/releases/download/{release}/manifest.json') as response:
        if hashlib.sha256(response.read()).hexdigest() != BASELINE_SHA256[release]:
            raise ValueError(f'{release} manifest.json no longer matches baseline/{release}.manifest.json')
    entry = frozen_lock_entry(tool, baseline_tool(baselines, release, name))
    output.mkdir(parents=True, exist_ok=True)
    for asset in entry['assets']:
        for filename in (asset['normalized'], asset['frozen_alias']):
            destination = output / filename
            if not destination.is_file() or digest(destination) != asset['sha256']:
                fetch(f'{CROSSBINS}/releases/download/{release}/{filename}', destination)
            if digest(destination) != asset['sha256']:
                raise ValueError(f'{filename} in {release} differs from its manifest hash')
    return entry


def frozen_filenames(config):
    return sorted(filename for entry in frozen_entries(config, baselines_for(config)).values()
                  for asset in entry['assets'] for filename in (asset['normalized'], asset['frozen_alias']))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lock', action='store_true', help='check binaries.lock.json')
    parser.add_argument('--outputs', action='store_true', help='rehash every frozen file in output/')
    parser.add_argument('--manifest', action='store_true', help='check output/manifest.json')
    parser.add_argument('--stage', metavar='TOOL', help='copy a frozen tool from its release into output/')
    parser.add_argument('--frozen-files', action='store_true', help='list every frozen file name')
    args = parser.parse_args()
    config = json.loads((ROOT / 'binaries.json').read_text())
    if args.stage:
        print(json.dumps(stage(config, args.stage, ROOT / 'output')))
    elif args.frozen_files:
        print('\n'.join(frozen_filenames(config)))
    else:
        validate(config,
                 json.loads((ROOT / 'binaries.lock.json').read_text()) if args.lock else None,
                 ROOT / 'output' if args.outputs else None,
                 json.loads((ROOT / 'output' / 'manifest.json').read_text()) if args.manifest else None)
