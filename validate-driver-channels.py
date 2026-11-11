#!/usr/bin/env python3
"""Keep legacy desktop clients on their compatible driver channel."""
import argparse
import json
from pathlib import Path

LEGACY_TAG = 'cua-driver-rs-v0.28.2'
BEARLY_TAG = 'cua-driver-rs-v0.34.1-bearly.1'


def validate(config, lock=None):
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


if __name__ == '__main__':
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lock', action='store_true')
    args = parser.parse_args()
    validate(json.loads((root / 'binaries.json').read_text()),
             json.loads((root / 'binaries.lock.json').read_text()) if args.lock else None)
