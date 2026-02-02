#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_FILE="$SCRIPT_DIR/binaries.lock.json"
OUTPUT_DIR="$SCRIPT_DIR/output"

# Required environment variables
: "${GITLAB_TOKEN:?Set GITLAB_TOKEN with api scope}"
: "${CI_PROJECT_ID:?Set CI_PROJECT_ID}"
CI_API_V4_URL="${CI_API_V4_URL:-https://gitlab.com/api/v4}"
CI_SERVER_URL="${CI_SERVER_URL:-https://gitlab.com}"

gitlab_api() {
  local method="$1" path="$2"
  shift 2
  curl -sfL -X "$method" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}${path}" "$@"
}

num_tools=$(jq '.tools | length' "$LOCK_FILE")
for (( i=0; i<num_tools; i++ )); do
  name=$(jq -r ".tools[$i].name" "$LOCK_FILE")
  version=$(jq -r ".tools[$i].version" "$LOCK_FILE")
  release_tag="${name}-${version}"

  # Check if release already exists
  if gitlab_api GET "/releases/$release_tag" > /dev/null 2>&1; then
    echo "Release $release_tag already exists, skipping"
    continue
  fi

  echo "Creating release $release_tag ..."

  # Ensure tag exists (ignore "already exists" error)
  gitlab_api POST "/repository/tags" \
    --data-urlencode "tag_name=$release_tag" \
    --data-urlencode "ref=HEAD" > /dev/null 2>&1 || true

  # Create release
  gitlab_api POST "/releases" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg tag "$release_tag" \
      --arg rname "$name $version" \
      --arg desc "Prebuilt $name binaries (upstream $version)" \
      '{tag_name: $tag, name: $rname, description: $desc}')" > /dev/null

  # Upload each asset and link to release
  num_assets=$(jq ".tools[$i].assets | length" "$LOCK_FILE")
  for (( j=0; j<num_assets; j++ )); do
    normalized=$(jq -r ".tools[$i].assets[$j].normalized" "$LOCK_FILE")
    filepath="$OUTPUT_DIR/$normalized"

    if [[ ! -f "$filepath" ]]; then
      echo "  WARNING: $filepath not found, skipping"
      continue
    fi

    echo "  Uploading $normalized ..."

    # Upload file to project uploads
    upload_response=$(gitlab_api POST "/uploads" -F "file=@$filepath")
    file_url=$(echo "$upload_response" | jq -r '.full_path')

    # Link uploaded file to release
    gitlab_api POST "/releases/$release_tag/assets/links" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg n "$normalized" \
        --arg u "${CI_SERVER_URL}${file_url}" \
        '{name: $n, url: $u, link_type: "other"}')" > /dev/null
  done

  echo "  => $release_tag published with $num_assets assets"
done

echo "Done."
