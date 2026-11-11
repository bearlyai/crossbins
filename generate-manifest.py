#!/usr/bin/env python3
"""Generate a release manifest from the exact bytes in output, including after signing."""
import hashlib
import json
import os
from pathlib import Path

root = Path(__file__).resolve().parent
lock = json.loads((root / 'binaries.lock.json').read_text())
config = json.loads((root / 'binaries.json').read_text())
repo_url = "https://github.com/" + os.environ["GITHUB_REPOSITORY"] if os.environ.get("GITHUB_REPOSITORY") else config["project_url"]
base = f"{repo_url}/releases/download/{lock['release_tag']}"
manifest = {
    'release_tag': lock['release_tag'],
    'download_base': base,
    'platform_map': {
        'os': {'darwin': 'darwin', 'linux': 'linux', 'win32': 'windows'},
        'arch': {'arm64': 'aarch64', 'x64': 'x86_64', 'ia32': 'i686', 'x86': 'i686'},
    },
    'tools': [],
}
for tool in lock['tools']:
    assets = []
    for asset in tool['assets']:
        platform = f"{asset['os']}-{asset['arch']}"
        if asset['variant']:
            platform += f"-{asset['variant']}"
        prefix = f"{tool['name']}-{tool['version']}-{platform}"
        if not asset['normalized'].startswith(prefix):
            raise ValueError(f"Unexpected normalized asset: {asset['normalized']}")
        suffix = asset['normalized'][len(prefix):]
        digest = hashlib.sha256()
        with (root / 'output' / asset['normalized']).open('rb') as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b''):
                digest.update(chunk)
        assets.append({
            'name': platform,
            'os': asset['os'],
            'arch': asset['arch'],
            'variant': asset['variant'],
            'sha256': digest.hexdigest(),
            'url': f"{base}/{tool['name']}-{platform}{suffix}",
        })
    if not assets:
        raise ValueError(f"No assets for {tool['name']}")
    manifest['tools'].append({'name': tool['name'], 'version': tool['version'], 'assets': assets})
(root / 'output' / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
