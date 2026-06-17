#!/usr/bin/env bash
set -euo pipefail

# Authenticode-sign the Windows binaries in ./output/ with Bearly's Azure Trusted
# Signing identity (publisher CN "Bearly, Inc."), so security teams can allow-list
# the managed binaries by *publisher identity* the same way they do the desktop
# installer. Runs cross-platform via jsign — no Windows runner required.
#
# The signing identity matches the Bearly desktop installer. All Azure-specific
# configuration is provided via environment (set from CI secrets) so nothing
# identifying is hardcoded in this public repo.
#
# Required env — a service principal holding the Trusted Signing "Certificate Profile
# Signer" role on the signing account:
#   AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET
#   TRUSTED_SIGNING_ACCOUNT, TRUSTED_SIGNING_PROFILE
# Optional env:
#   TRUSTED_SIGNING_ENDPOINT (defaults to the East US Trusted Signing endpoint)
#   TRUSTED_SIGNING_TOKEN    (pre-minted access token; bypasses az login)
#
# Note on Authenticode + Trusted Signing: leaf certificates live only ~3 days, so
# jsign timestamps every signature automatically (no --tsaurl needed). Allow-list by
# the stable publisher identity, NOT by the rotating cert thumbprint or the file hash.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
CACHE_DIR="$SCRIPT_DIR/.cache"

ENDPOINT="${TRUSTED_SIGNING_ENDPOINT:-https://eus.codesigning.azure.net/}"
ACCOUNT="${TRUSTED_SIGNING_ACCOUNT:-}"
PROFILE="${TRUSTED_SIGNING_PROFILE:-}"

JSIGN_VERSION="7.4"
JSIGN_SHA256="2abf2ade9ea322acc2d60c24794eadc465ff9380938fca4c932d09e0b25f1c28"
JSIGN_URL="https://github.com/ebourg/jsign/releases/download/${JSIGN_VERSION}/jsign-${JSIGN_VERSION}.jar"
JSIGN_JAR="$CACHE_DIR/jsign-${JSIGN_VERSION}.jar"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Windows binaries: normalized names always contain "-windows-" and end in ".exe".
windows_binaries=()
while IFS= read -r f; do
  windows_binaries+=("$f")
done < <(find "$OUTPUT_DIR" -type f -name '*-windows-*.exe' | sort)

if [[ "${#windows_binaries[@]}" -eq 0 ]]; then
  # Non-fatal: a release with no Windows assets (mac/linux only) is still valid.
  # publish.sh independently refuses to upload any unsigned Windows .exe.
  echo "sign-windows: no Windows binaries in output/ — nothing to sign."
  exit 0
fi

echo "sign-windows: ${#windows_binaries[@]} Windows binaries to sign:"
printf '  %s\n' "${windows_binaries[@]##*/}"

# Resolve a short-lived access token for the codesigning resource.
token="${TRUSTED_SIGNING_TOKEN:-}"
if [[ -z "$token" ]]; then
  : "${AZURE_TENANT_ID:?Set AZURE_TENANT_ID (or pass TRUSTED_SIGNING_TOKEN)}"
  : "${AZURE_CLIENT_ID:?Set AZURE_CLIENT_ID (or pass TRUSTED_SIGNING_TOKEN)}"
  : "${AZURE_CLIENT_SECRET:?Set AZURE_CLIENT_SECRET (or pass TRUSTED_SIGNING_TOKEN)}"
  command -v az >/dev/null 2>&1 || { echo "ERROR: az CLI not found and TRUSTED_SIGNING_TOKEN not set" >&2; exit 1; }
  echo "sign-windows: authenticating service principal ${AZURE_CLIENT_ID} ..."
  az login --service-principal \
    --username "$AZURE_CLIENT_ID" \
    --password "$AZURE_CLIENT_SECRET" \
    --tenant "$AZURE_TENANT_ID" \
    --allow-no-subscriptions >/dev/null
  token=$(az account get-access-token --resource https://codesigning.azure.net --query accessToken -o tsv)
fi
if [[ -z "$token" ]]; then
  echo "ERROR: failed to obtain a Trusted Signing access token" >&2
  exit 1
fi
# Keep the token out of CI logs (no-op outside Actions).
[[ "${GITHUB_ACTIONS:-}" == "true" ]] && echo "::add-mask::$token"

# Fetch + verify jsign, cached by version+hash so repeat runs skip the download.
mkdir -p "$CACHE_DIR"
if [[ ! -f "$JSIGN_JAR" ]] || [[ "$(sha256_file "$JSIGN_JAR")" != "$JSIGN_SHA256" ]]; then
  echo "sign-windows: downloading jsign ${JSIGN_VERSION} ..."
  tmp_jar="$JSIGN_JAR.tmp"
  curl -fSL -o "$tmp_jar" "$JSIGN_URL"
  actual=$(sha256_file "$tmp_jar")
  if [[ "$actual" != "$JSIGN_SHA256" ]]; then
    echo "ERROR: jsign jar checksum mismatch (expected $JSIGN_SHA256, got $actual)" >&2
    rm -f "$tmp_jar"
    exit 1
  fi
  mv "$tmp_jar" "$JSIGN_JAR"
fi

command -v java >/dev/null 2>&1 || { echo "ERROR: java not found (jsign needs a JRE)" >&2; exit 1; }

: "${ACCOUNT:?Set TRUSTED_SIGNING_ACCOUNT (the Trusted Signing account name)}"
: "${PROFILE:?Set TRUSTED_SIGNING_PROFILE (the certificate profile name)}"

# Sign every file in a single invocation: one certificate-chain fetch, N signatures
# (jsign fetches the chain once per run, so batching avoids doubling signing quota).
echo "sign-windows: signing ${#windows_binaries[@]} Windows binaries with Trusted Signing ..."
java -jar "$JSIGN_JAR" \
  --storetype TRUSTEDSIGNING \
  --keystore "$ENDPOINT" \
  --storepass "$token" \
  --alias "${ACCOUNT}/${PROFILE}" \
  --name "Bearly managed binary" \
  --url "https://github.com/bearlyai/crossbins" \
  --replace \
  "${windows_binaries[@]}"

echo "sign-windows: done — ${#windows_binaries[@]} binaries signed as \"Bearly, Inc.\""
