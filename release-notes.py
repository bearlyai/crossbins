#!/usr/bin/env python3
"""List every staged tool version against the frozen production baseline."""
import json
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parent
with urllib.request.urlopen('https://github.com/bearlyai/crossbins/releases/download/2026-09-21/manifest.json') as response:
    baseline = {tool['name']: tool['version'] for tool in json.load(response)['tools']}
manifest = json.loads((root / 'output/manifest.json').read_text())
lines = ['Tool versions compared with 2026-09-21:', '', '| Tool | 2026-09-21 | Staged |', '|---|---|---|']
for tool in manifest['tools']:
    lines.append(f"| {tool['name']} | {baseline.get(tool['name'], 'not present')} | {tool['version']} |")
(root / 'output/versions.md').write_text('\n'.join(lines) + '\n')
