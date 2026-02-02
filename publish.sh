#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_FILE="$SCRIPT_DIR/binaries.lock.json"
OUTPUT_DIR="$SCRIPT_DIR/output"

# Required environment variable
: "${GITHUB_TOKEN:?Set GITHUB_TOKEN with repo scope}"

# Derive repo from config or env
REPO="${GITHUB_REPOSITORY:-$(jq -r '.project_url' "$SCRIPT_DIR/binaries.json" | sed 's|https://github.com/||')}"

github_api() {
  local method="$1" path="$2"
  shift 2
  curl -sfL -X "$method" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}${path}" "$@"
}

num_tools=$(jq '.tools | length' "$LOCK_FILE")
for (( i=0; i<num_tools; i++ )); do
  name=$(jq -r ".tools[$i].name" "$LOCK_FILE")
  version=$(jq -r ".tools[$i].version" "$LOCK_FILE")
  release_tag="${name}-${version}"

  # Check if release already exists
  if github_api GET "/releases/tags/$release_tag" > /dev/null 2>&1; then
    echo "Release $release_tag already exists, skipping"
    continue
  fi

  echo "Creating release $release_tag ..."

  # Create release (this also creates the tag)
  release_response=$(github_api POST "/releases" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg tag "$release_tag" \
      --arg rname "$name $version" \
      --arg body "Prebuilt $name binaries (upstream $version)" \
      '{tag_name: $tag, name: $rname, body: $body, draft: false, prerelease: false}')")

  release_id=$(echo "$release_response" | jq -r '.id')
  upload_url=$(echo "$release_response" | jq -r '.upload_url' | sed 's/{?name,label}//')

  if [[ -z "$release_id" || "$release_id" == "null" ]]; then
    echo "  ERROR: failed to create release $release_tag"
    echo "  Response: $release_response"
    continue
  fi

  # Upload each asset
  num_assets=$(jq ".tools[$i].assets | length" "$LOCK_FILE")
  for (( j=0; j<num_assets; j++ )); do
    normalized=$(jq -r ".tools[$i].assets[$j].normalized" "$LOCK_FILE")
    filepath="$OUTPUT_DIR/$normalized"

    if [[ ! -f "$filepath" ]]; then
      echo "  WARNING: $filepath not found, skipping"
      continue
    fi

    echo "  Uploading $normalized ..."

    # Determine content type
    content_type="application/octet-stream"

    # Upload asset to release
    curl -sfL -X POST \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Content-Type: $content_type" \
      --data-binary "@$filepath" \
      "${upload_url}?name=${normalized}" > /dev/null
  done

  echo "  => $release_tag published with $num_assets assets"
done

echo "Done."
