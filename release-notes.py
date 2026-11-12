#!/usr/bin/env python3
"""List every staged tool version against the production baseline."""
import json
import runpy
from pathlib import Path

root = Path(__file__).resolve().parent
guard = runpy.run_path(str(root / 'validate-release.py'))
release = guard['PRODUCTION_BASELINE']
baseline = {tool['name']: tool['version'] for tool in guard['load_baseline'](release)['tools']}
config = {tool['name']: tool for tool in json.loads((root / 'binaries.json').read_text())['tools']}
manifest = json.loads((root / 'output/manifest.json').read_text())
lines = [f'Tool versions compared with {release}:', '', f'| Tool | {release} | Staged | Bytes |', '|---|---|---|---|']
for tool in manifest['tools']:
    source = config[tool['name']].get('frozen_release')
    bytes_from = f'unchanged from {source}' if source else 'new build'
    lines.append(f"| {tool['name']} | {baseline.get(tool['name'], 'not present')} | {tool['version']} | {bytes_from} |")
(root / 'output/versions.md').write_text('\n'.join(lines) + '\n')
