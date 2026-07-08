#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_FILE="$SCRIPT_DIR/binaries.lock.json"
OUTPUT_DIR="$SCRIPT_DIR/output"

# Required environment variable
: "${GITHUB_TOKEN:?Set GITHUB_TOKEN with repo scope}"

# Derive repo from config or env
REPO="${GITHUB_REPOSITORY:-$(jq -r '.project_url' "$SCRIPT_DIR/binaries.json" | sed 's|https://github.com/||')}"

CURL_COMMON=(-H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/vnd.github+json")
API_BASE="https://api.github.com/repos/${REPO}"

# Read release tag from lock file
release_tag=$(jq -r '.release_tag' "$LOCK_FILE")

# python3 + openssl confirm Windows binaries are signed by Bearly before publish.
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required to verify Windows signatures" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl is required to verify Windows signatures" >&2; exit 1; }

if jq -e '.tools[].assets[] | select(.os == "darwin")' "$LOCK_FILE" >/dev/null; then
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: macOS assets require publish.sh to run on macOS so codesign/notarization can be verified" >&2
    exit 1
  fi
  command -v codesign >/dev/null 2>&1 || { echo "ERROR: codesign is required to verify macOS signatures" >&2; exit 1; }
  command -v xcrun >/dev/null 2>&1 || { echo "ERROR: xcrun is required to verify macOS notarization" >&2; exit 1; }
fi

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# True only when the PE carries an Authenticode signature whose certificate chain
# includes "Bearly, Inc." — the publisher identity enterprises allow-list. A bare
# presence check is too weak: some upstream binaries (e.g. bun) already ship signed
# under a *different* publisher, which would not satisfy a Bearly allow-list.
pe_signed_by_bearly() {
  local filepath="$1" der
  der=$(mktemp)
  # Extract the embedded PKCS#7 (strip the 8-byte WIN_CERTIFICATE header -> DER).
  if ! python3 - "$filepath" >"$der" <<'PY'
import struct, sys
try:
    data = open(sys.argv[1], "rb").read()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        sys.exit(2)
    magic = struct.unpack_from("<H", data, pe + 24)[0]
    dirs = pe + 24 + (112 if magic == 0x20b else 96)  # data directory array (PE32+ vs PE32)
    off, size = struct.unpack_from("<II", data, dirs + 4 * 8)  # entry 4 = IMAGE_DIRECTORY_ENTRY_SECURITY
    if size == 0:
        sys.exit(1)  # unsigned
    sys.stdout.buffer.write(data[off + 8: off + size])
except Exception:
    sys.exit(3)
PY
  then
    rm -f "$der"
    return 1
  fi
  if openssl pkcs7 -inform DER -in "$der" -print_certs -noout 2>/dev/null | grep -qi "Bearly, Inc\."; then
    rm -f "$der"
    return 0
  fi
  rm -f "$der"
  return 1
}

codesign_identity_ok() {
  local target="$1" require_notary="${2:-false}" details
  if ! codesign --verify --deep --strict --verbose=2 "$target" >/dev/null 2>&1; then
    return 1
  fi
  details=$(codesign -dv --verbose=4 "$target" 2>&1)
  if [[ -n "${APPLE_TEAM_ID:-}" ]]; then
    grep -q "TeamIdentifier=${APPLE_TEAM_ID}" <<<"$details" || return 1
  else
    grep -q 'Authority=Developer ID Application: .*Bearly' <<<"$details" || return 1
  fi
  if [[ "$require_notary" == "true" ]]; then
    xcrun stapler validate "$target" >/dev/null 2>&1 || return 1
  fi
}

macos_asset_signed_by_bearly() {
  local filepath="$1" temp_dir app_path executable
  if [[ "$filepath" == *.tar.gz ]]; then
    temp_dir=$(mktemp -d)
    tar xzf "$filepath" -C "$temp_dir"
    while IFS= read -r app_path; do
      if ! codesign_identity_ok "$app_path" true; then
        rm -rf "$temp_dir"
        return 1
      fi
    done < <(find "$temp_dir" -type d -name '*.app' | sort)
    while IFS= read -r executable; do
      if file "$executable" | grep -q 'Mach-O' && ! codesign_identity_ok "$executable" false; then
        rm -rf "$temp_dir"
        return 1
      fi
    done < <(find "$temp_dir" -type f -perm -111 | sort)
    rm -rf "$temp_dir"
    return 0
  fi
  if file "$filepath" | grep -q 'Mach-O'; then
    codesign_identity_ok "$filepath" false
    return $?
  fi
  return 1
}

# Build release body with tool versions
release_body="Binary set ${release_tag}"$'\n\n'
num_tools=$(jq '.tools | length' "$LOCK_FILE")
for (( i=0; i<num_tools; i++ )); do
  name=$(jq -r ".tools[$i].name" "$LOCK_FILE")
  version=$(jq -r ".tools[$i].version" "$LOCK_FILE")
  release_body+="- **${name}** ${version}"$'\n'
done

# Validate all binaries before creating the release
echo "Validating binaries before publish..."
missing=0
invalid=0
for (( i=0; i<num_tools; i++ )); do
  tool_name=$(jq -r ".tools[$i].name" "$LOCK_FILE")
  num_assets=$(jq ".tools[$i].assets | length" "$LOCK_FILE")

  if [[ "$num_assets" -eq 0 ]]; then
    echo "  ERROR: $tool_name has zero assets in lock file"
    (( invalid++ ))
    continue
  fi

  for (( j=0; j<num_assets; j++ )); do
    normalized=$(jq -r ".tools[$i].assets[$j].normalized" "$LOCK_FILE")
    os=$(jq -r ".tools[$i].assets[$j].os" "$LOCK_FILE")
    filepath="$OUTPUT_DIR/$normalized"

    if [[ ! -f "$filepath" ]]; then
      echo "  ERROR: $normalized is missing from output/"
      (( missing++ ))
      continue
    fi

    filesize=$(wc -c < "$filepath" | tr -d ' ')
    if [[ "$filesize" -lt 1024 ]]; then
      echo "  ERROR: $normalized is only $filesize bytes (expected >= 1KB)"
      (( invalid++ ))
      continue
    fi

    if head -c 256 "$filepath" | grep -qi '<!doctype\|<html'; then
      echo "  ERROR: $normalized appears to be HTML, not a binary"
      (( invalid++ ))
      continue
    fi

    # Never publish a Windows binary that isn't signed by Bearly — the whole point.
    if [[ "$os" == "windows" && "$filepath" == *.exe ]] && ! pe_signed_by_bearly "$filepath"; then
      echo "  ERROR: $normalized is not signed by \"Bearly, Inc.\" (run ./sign-windows.sh before publishing)"
      (( invalid++ ))
      continue
    fi

    # Never publish a macOS executable/app bundle that isn't Bearly-signed.
    if [[ "$os" == "darwin" ]] && ! macos_asset_signed_by_bearly "$filepath"; then
      echo "  ERROR: $normalized is not signed/notarized by Bearly (run ./sign-macos.sh before publishing)"
      (( invalid++ ))
      continue
    fi
  done
done

if [[ "$missing" -gt 0 || "$invalid" -gt 0 ]]; then
  echo "ERROR: $missing missing, $invalid invalid binaries — aborting publish"
  exit 1
fi
echo "  All binaries validated"

echo "  Repo: $REPO"

delete_existing_asset() {
  local asset_name="$1"
  local asset_id="" page=1

  while [[ "$page" -le 5 ]]; do
    asset_id=$(curl -sfL "${CURL_COMMON[@]}" \
      "${API_BASE}/releases/${release_id}/assets?per_page=100&page=${page}" |
      jq -r --arg name "$asset_name" '.[] | select(.name == $name) | .id' | head -1)
    [[ -n "$asset_id" ]] && break
    (( page++ ))
  done

  if [[ -n "$asset_id" ]]; then
    curl -sfL -X DELETE "${CURL_COMMON[@]}" \
      "${API_BASE}/releases/assets/${asset_id}" > /dev/null
  fi
}

# Create release, or update the existing same-day release when automation already ran.
release_lookup=$(curl -s -w '\n%{http_code}' "${CURL_COMMON[@]}" \
  "${API_BASE}/releases/tags/$release_tag")
http_code=$(echo "$release_lookup" | tail -1)
response_body=$(echo "$release_lookup" | sed '$d')

if [[ "$http_code" == "200" ]]; then
  echo "Updating existing release $release_tag ..."
  existing_release_id=$(echo "$response_body" | jq -r '.id')
  release_response=$(curl -s -w '\n%{http_code}' -X PATCH "${CURL_COMMON[@]}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg rname "Binary set ${release_tag}" \
      --arg body "$release_body" \
      '{name: $rname, body: $body, draft: false, prerelease: false}')" \
    "${API_BASE}/releases/${existing_release_id}")
  http_code=$(echo "$release_response" | tail -1)
  response_body=$(echo "$release_response" | sed '$d')
else
  echo "Creating release $release_tag ..."
  release_response=$(curl -s -w '\n%{http_code}' -X POST "${CURL_COMMON[@]}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg tag "$release_tag" \
      --arg rname "Binary set ${release_tag}" \
      --arg body "$release_body" \
      '{tag_name: $tag, name: $rname, body: $body, draft: false, prerelease: false}')" \
    "${API_BASE}/releases")
  http_code=$(echo "$release_response" | tail -1)
  response_body=$(echo "$release_response" | sed '$d')
fi

if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
  echo "ERROR: failed to create/update release (HTTP $http_code)"
  echo "$response_body"
  exit 1
fi

release_id=$(echo "$response_body" | jq -r '.id')
upload_url=$(echo "$response_body" | jq -r '.upload_url' | sed 's/{?name,label}//')

echo "  Release ID: $release_id"
echo "  Upload URL: $upload_url"

# Upload all assets from all tools
total=0
for (( i=0; i<num_tools; i++ )); do
  name=$(jq -r ".tools[$i].name" "$LOCK_FILE")
  num_assets=$(jq ".tools[$i].assets | length" "$LOCK_FILE")

  for (( j=0; j<num_assets; j++ )); do
    normalized=$(jq -r ".tools[$i].assets[$j].normalized" "$LOCK_FILE")
    filepath="$OUTPUT_DIR/$normalized"

    if [[ ! -f "$filepath" ]]; then
      echo "  WARNING: $filepath not found, skipping"
      continue
    fi

    filesize=$(wc -c < "$filepath" | tr -d ' ')
    echo "  Uploading $normalized (${filesize} bytes) ..."

    delete_existing_asset "$normalized"
    upload_response=$(curl -s -w '\n%{http_code}' -X POST \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Content-Type: application/octet-stream" \
      --data-binary "@$filepath" \
      "${upload_url}?name=${normalized}")

    upload_code=$(echo "$upload_response" | tail -1)
    upload_body=$(echo "$upload_response" | sed '$d')

    if [[ "$upload_code" -lt 200 || "$upload_code" -ge 300 ]]; then
      echo "  ERROR: upload failed (HTTP $upload_code) for $normalized"
      echo "  $upload_body"
      exit 1
    fi

    (( ++total ))
  done
done

# Upload version-less copies for stable /releases/latest/download/ URLs
echo "Uploading version-less asset names..."
for (( i=0; i<num_tools; i++ )); do
  name=$(jq -r ".tools[$i].name" "$LOCK_FILE")
  num_assets=$(jq ".tools[$i].assets | length" "$LOCK_FILE")

  for (( j=0; j<num_assets; j++ )); do
    normalized=$(jq -r ".tools[$i].assets[$j].normalized" "$LOCK_FILE")
    os=$(jq -r ".tools[$i].assets[$j].os" "$LOCK_FILE")
    arch=$(jq -r ".tools[$i].assets[$j].arch" "$LOCK_FILE")
    variant=$(jq -r ".tools[$i].assets[$j].variant" "$LOCK_FILE")
    version=$(jq -r ".tools[$i].version" "$LOCK_FILE")
    filepath="$OUTPUT_DIR/$normalized"
    [[ ! -f "$filepath" ]] && continue

    variant_part=""
    [[ -n "$variant" ]] && variant_part="-${variant}"
    versioned_prefix="${name}-${version}-${os}-${arch}${variant_part}"
    suffix="${normalized#"$versioned_prefix"}"
    latest_name="${name}-${os}-${arch}${variant_part}${suffix}"

    delete_existing_asset "$latest_name"
    curl -s -w '\n%{http_code}' -X POST \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Content-Type: application/octet-stream" \
      --data-binary "@$filepath" \
      "${upload_url}?name=${latest_name}" > /dev/null

    echo "  $latest_name"
    (( ++total ))
  done
done

# Generate and upload manifest.json
download_base="https://github.com/${REPO}/releases/latest/download"

# Hash the files we actually uploaded so the manifest reflects post-signing bytes.
# The lock's sha256 is the *unsigned* output hash (it anchors release-tag change
# detection in update.sh and must stay signing-independent), so it can't be trusted
# for the manifest once Windows binaries are signed.
hashes_json="{}"
for (( i=0; i<num_tools; i++ )); do
  num_assets=$(jq ".tools[$i].assets | length" "$LOCK_FILE")
  for (( j=0; j<num_assets; j++ )); do
    normalized=$(jq -r ".tools[$i].assets[$j].normalized" "$LOCK_FILE")
    filepath="$OUTPUT_DIR/$normalized"
    [[ -f "$filepath" ]] || continue
    hashes_json=$(jq --arg n "$normalized" --arg h "$(sha256_file "$filepath")" '. + {($n): $h}' <<<"$hashes_json")
  done
done

# Build manifest with jq — includes full URLs and platform mapping for consumers
manifest=$(jq -n \
  --arg base "$download_base" \
  --arg tag "$release_tag" \
  --argjson hashes "$hashes_json" \
  --slurpfile lock "$LOCK_FILE" \
'
{
  release_tag: $tag,
  download_base: $base,
  platform_map: {
    os:   { darwin: "darwin", linux: "linux", win32: "windows" },
    arch: { arm64: "aarch64", x64: "x86_64", ia32: "i686", x86: "i686" }
  },
  tools: [
    $lock[0].tools[] | . as $tool | {
      name: .name,
      version: .version,
      assets: [
        .assets[] | {
          name: (
            .os + "-" + .arch
            + (if .variant != "" then "-" + .variant else "" end)
          ),
          os,
          arch,
          variant,
          sha256: ($hashes[.normalized] // .sha256 // ""),
          url: (
            $base + "/" + $tool.name + "-" + .os + "-" + .arch
            + (if .variant != "" then "-" + .variant else "" end)
            + (
              . as $asset
              | ($tool.name + "-" + $tool.version + "-" + $asset.os + "-" + $asset.arch + (if $asset.variant != "" then "-" + $asset.variant else "" end)) as $prefix
              | ($asset.normalized | ltrimstr($prefix))
            )
          )
        }
      ]
    }
  ]
}')

echo "$manifest" > "$OUTPUT_DIR/manifest.json"
delete_existing_asset "manifest.json"
curl -s -w '\n%{http_code}' -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@$OUTPUT_DIR/manifest.json" \
  "${upload_url}?name=manifest.json" > /dev/null
echo "  manifest.json"
(( ++total ))

echo "=> $release_tag published with $total assets (versioned + version-less + manifest)"
echo "Done."
