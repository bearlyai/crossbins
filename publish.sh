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

# Read set version from lock file
set_version=$(jq -r '.version' "$LOCK_FILE")
release_tag="v${set_version}"

# Build release body with tool versions
release_body="Binary set ${release_tag}"$'\n\n'
num_tools=$(jq '.tools | length' "$LOCK_FILE")
for (( i=0; i<num_tools; i++ )); do
  name=$(jq -r ".tools[$i].name" "$LOCK_FILE")
  version=$(jq -r ".tools[$i].version" "$LOCK_FILE")
  release_body+="- **${name}** ${version}"$'\n'
done

# Check if release already exists
http_code=$(curl -s -o /dev/null -w '%{http_code}' "${CURL_COMMON[@]}" \
  "${API_BASE}/releases/tags/$release_tag")
if [[ "$http_code" == "200" ]]; then
  echo "Release $release_tag already exists, nothing to do"
  exit 0
fi

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
  done
done

if [[ "$missing" -gt 0 || "$invalid" -gt 0 ]]; then
  echo "ERROR: $missing missing, $invalid invalid binaries — aborting publish"
  exit 1
fi
echo "  All binaries validated"

echo "Creating release $release_tag ..."
echo "  Repo: $REPO"

# Create release
release_response=$(curl -s -w '\n%{http_code}' -X POST "${CURL_COMMON[@]}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg tag "$release_tag" \
    --arg rname "Binary set ${release_tag}" \
    --arg body "$release_body" \
    '{tag_name: $tag, name: $rname, body: $body, draft: false, prerelease: false}')" \
  "${API_BASE}/releases")

# Split response body and HTTP status code
http_code=$(echo "$release_response" | tail -1)
response_body=$(echo "$release_response" | sed '$d')

if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
  echo "ERROR: failed to create release (HTTP $http_code)"
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

    (( total++ ))
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
    filepath="$OUTPUT_DIR/$normalized"
    [[ ! -f "$filepath" ]] && continue

    suffix=""
    [[ "$os" == "windows" ]] && suffix=".exe"
    variant_part=""
    [[ -n "$variant" ]] && variant_part="-${variant}"
    latest_name="${name}-${os}-${arch}${variant_part}${suffix}"

    curl -s -w '\n%{http_code}' -X POST \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Content-Type: application/octet-stream" \
      --data-binary "@$filepath" \
      "${upload_url}?name=${latest_name}" > /dev/null

    echo "  $latest_name"
    (( total++ ))
  done
done

# Generate and upload manifest.json
download_base="https://github.com/${REPO}/releases/latest/download"

# Build manifest with jq — includes full URLs and platform mapping for consumers
manifest=$(jq -n \
  --arg base "$download_base" \
  --arg tag "$release_tag" \
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
          url: (
            $base + "/" + $tool.name + "-" + .os + "-" + .arch
            + (if .variant != "" then "-" + .variant else "" end)
            + (if .os == "windows" then ".exe" else "" end)
          )
        }
      ]
    }
  ]
}')

echo "$manifest" > "$OUTPUT_DIR/manifest.json"
curl -s -w '\n%{http_code}' -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@$OUTPUT_DIR/manifest.json" \
  "${upload_url}?name=manifest.json" > /dev/null
echo "  manifest.json"
(( total++ ))

echo "=> $release_tag published with $total assets (versioned + version-less + manifest)"
echo "Done."
