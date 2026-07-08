# crossbins

Republishes prebuilt binaries from upstream GitHub releases with normalized filenames.

## Tools tracked

| Tool | Upstream repo | Binary name |
|------|--------------|-------------|
| rg | BurntSushi/ripgrep | `rg` |
| bun | oven-sh/bun | `bun` |
| uv | astral-sh/uv | `uv` |
| yt-dlp | yt-dlp/yt-dlp | `yt-dlp` |
| ffmpeg | BtbN/FFmpeg-Builds; Martin Riedl macOS builds | `ffmpeg` |

## Naming convention

```
{tool}-{version}-{os}-{arch}[-{variant}][.exe]
```

Examples: `rg-15.1.0-linux-aarch64`, `uv-0.11.3-linux-x86_64-musl`, `yt-dlp-2026.03.17-darwin-universal`

## Available binaries

<!-- BINARIES_START -->
**Release: [2026-07-08](https://github.com/bearlyai/crossbins/releases/tag/2026-07-08)**

### rg 15.1.0

| File | OS | Arch | Variant | Download |
|------|----|------|---------|----------|
| `rg-15.1.0-darwin-x86_64` | darwin | x86_64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/rg-15.1.0-darwin-x86_64) |
| `rg-15.1.0-darwin-aarch64` | darwin | aarch64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/rg-15.1.0-darwin-aarch64) |
| `rg-15.1.0-windows-aarch64.exe` | windows | aarch64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/rg-15.1.0-windows-aarch64.exe) |
| `rg-15.1.0-windows-x86_64.exe` | windows | x86_64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/rg-15.1.0-windows-x86_64.exe) |
| `rg-15.1.0-linux-armv7-musl` | linux | armv7 | musl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/rg-15.1.0-linux-armv7-musl) |
| `rg-15.1.0-linux-i686` | linux | i686 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/rg-15.1.0-linux-i686) |
| `rg-15.1.0-linux-armv7` | linux | armv7 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/rg-15.1.0-linux-armv7) |
| `rg-15.1.0-linux-aarch64` | linux | aarch64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/rg-15.1.0-linux-aarch64) |
| `rg-15.1.0-windows-i686.exe` | windows | i686 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/rg-15.1.0-windows-i686.exe) |
| `rg-15.1.0-linux-s390x` | linux | s390x | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/rg-15.1.0-linux-s390x) |
| `rg-15.1.0-linux-x86_64-musl` | linux | x86_64 | musl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/rg-15.1.0-linux-x86_64-musl) |

### bun 1.3.14

| File | OS | Arch | Variant | Download |
|------|----|------|---------|----------|
| `bun-1.3.14-darwin-aarch64` | darwin | aarch64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/bun-1.3.14-darwin-aarch64) |
| `bun-1.3.14-darwin-x86_64` | darwin | x86_64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/bun-1.3.14-darwin-x86_64) |
| `bun-1.3.14-linux-aarch64-musl` | linux | aarch64 | musl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/bun-1.3.14-linux-aarch64-musl) |
| `bun-1.3.14-linux-aarch64` | linux | aarch64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/bun-1.3.14-linux-aarch64) |
| `bun-1.3.14-linux-x86_64-musl` | linux | x86_64 | musl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/bun-1.3.14-linux-x86_64-musl) |
| `bun-1.3.14-linux-x86_64` | linux | x86_64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/bun-1.3.14-linux-x86_64) |
| `bun-1.3.14-windows-x86_64.exe` | windows | x86_64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/bun-1.3.14-windows-x86_64.exe) |

### uv 0.11.28

| File | OS | Arch | Variant | Download |
|------|----|------|---------|----------|
| `uv-0.11.28-darwin-aarch64` | darwin | aarch64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-darwin-aarch64) |
| `uv-0.11.28-windows-aarch64.exe` | windows | aarch64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-windows-aarch64.exe) |
| `uv-0.11.28-linux-aarch64` | linux | aarch64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-linux-aarch64) |
| `uv-0.11.28-linux-aarch64-musl` | linux | aarch64 | musl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-linux-aarch64-musl) |
| `uv-0.11.28-linux-arm-musl` | linux | arm | musl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-linux-arm-musl) |
| `uv-0.11.28-linux-armv7` | linux | armv7 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-linux-armv7) |
| `uv-0.11.28-linux-armv7-musl` | linux | armv7 | musl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-linux-armv7-musl) |
| `uv-0.11.28-windows-i686.exe` | windows | i686 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-windows-i686.exe) |
| `uv-0.11.28-linux-i686` | linux | i686 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-linux-i686) |
| `uv-0.11.28-linux-i686-musl` | linux | i686 | musl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-linux-i686-musl) |
| `uv-0.11.28-linux-ppc64le` | linux | ppc64le | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-linux-ppc64le) |
| `uv-0.11.28-linux-riscv64` | linux | riscv64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-linux-riscv64) |
| `uv-0.11.28-linux-s390x` | linux | s390x | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-linux-s390x) |
| `uv-0.11.28-darwin-x86_64` | darwin | x86_64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-darwin-x86_64) |
| `uv-0.11.28-windows-x86_64.exe` | windows | x86_64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-windows-x86_64.exe) |
| `uv-0.11.28-linux-x86_64` | linux | x86_64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-linux-x86_64) |
| `uv-0.11.28-linux-x86_64-musl` | linux | x86_64 | musl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/uv-0.11.28-linux-x86_64-musl) |

### yt-dlp 2026.07.04

| File | OS | Arch | Variant | Download |
|------|----|------|---------|----------|
| `yt-dlp-2026.07.04-linux-x86_64` | linux | x86_64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/yt-dlp-2026.07.04-linux-x86_64) |
| `yt-dlp-2026.07.04-linux-aarch64` | linux | aarch64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/yt-dlp-2026.07.04-linux-aarch64) |
| `yt-dlp-2026.07.04-linux-armv7` | linux | armv7 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/yt-dlp-2026.07.04-linux-armv7) |
| `yt-dlp-2026.07.04-linux-x86_64-musl` | linux | x86_64 | musl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/yt-dlp-2026.07.04-linux-x86_64-musl) |
| `yt-dlp-2026.07.04-linux-aarch64-musl` | linux | aarch64 | musl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/yt-dlp-2026.07.04-linux-aarch64-musl) |
| `yt-dlp-2026.07.04-darwin-universal` | darwin | universal | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/yt-dlp-2026.07.04-darwin-universal) |
| `yt-dlp-2026.07.04-windows-x86_64.exe` | windows | x86_64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/yt-dlp-2026.07.04-windows-x86_64.exe) |
| `yt-dlp-2026.07.04-windows-aarch64.exe` | windows | aarch64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/yt-dlp-2026.07.04-windows-aarch64.exe) |
| `yt-dlp-2026.07.04-windows-i686.exe` | windows | i686 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/yt-dlp-2026.07.04-windows-i686.exe) |

### ffmpeg 8.1

| File | OS | Arch | Variant | Download |
|------|----|------|---------|----------|
| `ffmpeg-8.1-linux-x86_64-gpl` | linux | x86_64 | gpl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/ffmpeg-8.1-linux-x86_64-gpl) |
| `ffmpeg-8.1-linux-aarch64-gpl` | linux | aarch64 | gpl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/ffmpeg-8.1-linux-aarch64-gpl) |
| `ffmpeg-8.1-windows-x86_64-gpl.exe` | windows | x86_64 | gpl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/ffmpeg-8.1-windows-x86_64-gpl.exe) |
| `ffmpeg-8.1-windows-aarch64-gpl.exe` | windows | aarch64 | gpl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/ffmpeg-8.1-windows-aarch64-gpl.exe) |
| `ffmpeg-8.1-darwin-x86_64-gpl` | darwin | x86_64 | gpl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/ffmpeg-8.1-darwin-x86_64-gpl) |
| `ffmpeg-8.1-darwin-aarch64-gpl` | darwin | aarch64 | gpl | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/ffmpeg-8.1-darwin-aarch64-gpl) |

### cua-driver 0.7.1

| File | OS | Arch | Variant | Download |
|------|----|------|---------|----------|
| `cua-driver-0.7.1-darwin-universal.tar.gz` | darwin | universal | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/cua-driver-0.7.1-darwin-universal.tar.gz) |
| `cua-driver-0.7.1-linux-x86_64` | linux | x86_64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/cua-driver-0.7.1-linux-x86_64) |
| `cua-driver-0.7.1-linux-aarch64` | linux | aarch64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/cua-driver-0.7.1-linux-aarch64) |
| `cua-driver-0.7.1-windows-x86_64.exe` | windows | x86_64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/cua-driver-0.7.1-windows-x86_64.exe) |
| `cua-driver-0.7.1-windows-aarch64.exe` | windows | aarch64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/cua-driver-0.7.1-windows-aarch64.exe) |

### cua-driver-uia 0.7.1

| File | OS | Arch | Variant | Download |
|------|----|------|---------|----------|
| `cua-driver-uia-0.7.1-windows-x86_64.exe` | windows | x86_64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/cua-driver-uia-0.7.1-windows-x86_64.exe) |
| `cua-driver-uia-0.7.1-windows-aarch64.exe` | windows | aarch64 | - | [download](https://github.com/bearlyai/crossbins/releases/download/2026-07-08/cua-driver-uia-0.7.1-windows-aarch64.exe) |

<!-- BINARIES_END -->

## Download (stable URLs, no auth needed)

Each release includes version-less asset names. GitHub's `/releases/latest` redirect
gives you a stable URL that always points to the most recent published version:

```bash
# Download a binary
curl -fSL https://github.com/bearlyai/crossbins/releases/latest/download/rg-linux-x86_64 -o rg
chmod +x rg

# Check current versions programmatically
curl -fSL https://github.com/bearlyai/crossbins/releases/latest/download/manifest.json | jq .
```

URL pattern: `https://github.com/bearlyai/crossbins/releases/latest/download/{tool}-{os}-{arch}[-{variant}][.exe]`

### Platform naming

| crossbins | Electron / Node.js equivalent |
|-----------|-------------------------------|
| `darwin` | `darwin` |
| `linux` | `linux` |
| `windows` | `win32` |
| `aarch64` | `arm64` |
| `x86_64` | `x64` |
| `i686` | `ia32` |
| `universal` | (macOS universal — fallback when no arch-specific build exists) |

The `manifest.json` includes a `platform_map` with these translations.

## Usage

### Local testing

```bash
./update.sh          # downloads, extracts, normalizes into ./output/
ls -la output/
file output/*        # verify binary types
```

Set `GITHUB_TOKEN` to avoid API rate limits when testing repeatedly.

### Adding a new tool

Two config modes in `binaries.json`:

**Archive-based tools** (rg, bun, uv) — use `asset_prefix` + `triple_map`:
- `name` — short name used in output filenames
- `repo` — GitHub `owner/repo`
- `binary_name` — the executable filename inside the archive
- `asset_prefix` — pattern to match assets (`{VERSION}` is replaced with the resolved version)
- `triple_map` — maps upstream platform strings to `{os, arch, variant}`

**Raw binary tools** (yt-dlp) — use `explicit_assets`:
- `name`, `repo`, `binary_name` — same as above
- `release_tag_pattern` — optional regex to select only matching upstream release tags
- `version_probe_regex` — optional regex with a named `version` capture, resolved from upstream asset names
- `checksum_asset` — optional release asset containing SHA256 checksums to verify before extraction
- `explicit_assets` — list of `{asset_name, source_type, os, arch, variant}` entries. `asset_name`, `asset_regex`, or `url` may use `{VERSION}` from `version_probe_regex`; `checksum_url` may use `{EFFECTIVE_URL}` after redirects are resolved. `source_type` supports `raw`, `zip`, `tar.gz`, and `tar.xz`.
- `checksum_name` and `version_check_regex` — optional direct URL checks for checksum file entries and redirect targets

### Updating versions

Just run `./update.sh` — it always fetches the latest stable (non-draft, non-prerelease) release from GitHub.

## Windows code signing

The published Windows binaries (`*-windows-*.exe`) are Authenticode-signed under Bearly's
identity (`CN = Bearly, Inc.`) using [Azure Trusted Signing](https://learn.microsoft.com/azure/trusted-signing/) —
the **same certificate identity as the Bearly desktop installer**. Signing runs in CI via
[`sign-windows.sh`](sign-windows.sh) using [jsign](https://ebourg.github.io/jsign/), so no
Windows runner is needed, and `publish.sh` refuses to upload any Windows binary that is not
signed as `Bearly, Inc.` (upstream signatures from other publishers do not satisfy the check).

> **Allow-listing in managed environments (BeyondTrust, AppLocker, WDAC, etc.): match the
> publisher identity `Bearly, Inc.` — not a file hash or certificate thumbprint.** Trusted
> Signing issues short-lived leaf certificates (~3-day lifetime, auto-timestamped) that rotate,
> and each binary's hash changes whenever its upstream tool updates. The publisher identity is
> the only value that stays constant across every version, and it matches the installer.

### CI setup

The signing step needs an Azure service principal with the Trusted Signing **Certificate
Profile Signer** role, exposed to this repo as Actions secrets (no Azure-specific values are
hardcoded in this public repo):

| Secret | Description |
|--------|-------------|
| `AZURE_TENANT_ID` | Azure AD tenant (directory) ID |
| `AZURE_CLIENT_ID` | App Registration client ID |
| `AZURE_CLIENT_SECRET` | App Registration secret value |
| `TRUSTED_SIGNING_ACCOUNT` | Trusted Signing account name |
| `TRUSTED_SIGNING_PROFILE` | Certificate profile name |

The endpoint defaults to the East US Trusted Signing endpoint (`TRUSTED_SIGNING_ENDPOINT` to
override). macOS and Linux binaries are not signed.

## Automation

A GitHub Actions workflow runs weekly (Monday 9am UTC) to check for upstream updates.
When versions change, it publishes a new release and commits the updated lock file and README.
Failures create a GitHub issue labeled `automation`.

The workflow also runs on pushes to `main` (when `binaries.json` or `*.sh` change) and can be triggered manually.

## Dependencies

`curl`, `jq`, `tar`, `unzip`, `find` — available on any Linux/macOS system and in the CI image.
