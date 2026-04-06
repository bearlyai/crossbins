#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/binaries.json"
LOCK_FILE="$SCRIPT_DIR/binaries.lock.json"
OUTPUT_DIR="$SCRIPT_DIR/output"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Optional GitHub token to avoid rate limits
CURL_AUTH=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  CURL_AUTH=(-H "Authorization: token $GITHUB_TOKEN")
fi

mkdir -p "$OUTPUT_DIR"

# Validate a binary is not empty, not HTML, and meets minimum size
validate_binary() {
  local filepath="$1" name="$2"
  local filesize

  if [[ ! -f "$filepath" ]]; then
    echo "  ERROR: $name does not exist after extraction"
    return 1
  fi

  filesize=$(wc -c < "$filepath" | tr -d ' ')
  if [[ "$filesize" -lt 1024 ]]; then
    echo "  ERROR: $name is only $filesize bytes (expected >= 1KB)"
    return 1
  fi

  # Check for HTML error pages (common when download URL returns a web page)
  if head -c 256 "$filepath" | grep -qi '<!doctype\|<html'; then
    echo "  ERROR: $name appears to be an HTML page, not a binary"
    return 1
  fi

  return 0
}

# Read existing lock release tag (default empty)
old_release_tag=""
if [[ -f "$LOCK_FILE" ]]; then
  old_release_tag=$(jq -r '.release_tag // empty' "$LOCK_FILE")
fi

# Initialize lock structure
lock_json='{"release_tag":"","tools":[]}'

num_tools=$(jq '.tools | length' "$CONFIG")
for (( i=0; i<num_tools; i++ )); do
  name=$(jq -r ".tools[$i].name" "$CONFIG")
  repo=$(jq -r ".tools[$i].repo" "$CONFIG")
  binary_name=$(jq -r ".tools[$i].binary_name // empty" "$CONFIG")

  # Fetch latest stable release (first non-draft, non-prerelease)
  releases_json=$(curl -sfL "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
    "https://api.github.com/repos/$repo/releases?per_page=20")

  release=$(echo "$releases_json" | jq -e 'map(select(.draft == false and .prerelease == false)) | first')
  tag=$(echo "$release" | jq -r '.tag_name')

  # Clean version: strip leading "v", "bun-v", etc.
  clean_version="$tag"
  clean_version="${clean_version#bun-v}"
  clean_version="${clean_version#v}"

  echo "=== $name: version $clean_version (tag: $tag) ==="

  locked_assets="[]"

  # Check if tool uses explicit_assets mode
  has_explicit=$(jq -r ".tools[$i].explicit_assets // empty" "$CONFIG")

  if [[ -n "$has_explicit" ]]; then
    # --- explicit_assets mode (for tools like yt-dlp with non-standard naming) ---
    num_explicit=$(jq ".tools[$i].explicit_assets | length" "$CONFIG")
    for (( j=0; j<num_explicit; j++ )); do
      asset_name=$(jq -r ".tools[$i].explicit_assets[$j].asset_name" "$CONFIG")
      source_type=$(jq -r ".tools[$i].explicit_assets[$j].source_type" "$CONFIG")
      os=$(jq -r ".tools[$i].explicit_assets[$j].os" "$CONFIG")
      arch=$(jq -r ".tools[$i].explicit_assets[$j].arch" "$CONFIG")
      variant=$(jq -r ".tools[$i].explicit_assets[$j].variant // empty" "$CONFIG")

      # Find this asset in the release — fail hard if missing
      download_url=$(echo "$release" | jq -r \
        --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url')
      if [[ -z "$download_url" ]]; then
        echo "  ERROR: expected asset '$asset_name' not found in release $tag"
        exit 1
      fi

      # Build normalized name
      suffix=""
      [[ "$os" == "windows" ]] && suffix=".exe"
      variant_part=""
      [[ -n "$variant" ]] && variant_part="-${variant}"
      normalized="${name}-${clean_version}-${os}-${arch}${variant_part}${suffix}"

      echo "  $asset_name -> $normalized"

      # Download
      curl -fSL -o "$WORK_DIR/$asset_name" "$download_url"

      if [[ "$source_type" == "raw" ]]; then
        # Raw binary — just copy directly
        cp "$WORK_DIR/$asset_name" "$OUTPUT_DIR/$normalized"
        chmod +x "$OUTPUT_DIR/$normalized"
      elif [[ "$source_type" == "zip" ]]; then
        # Zip archive — extract and find binary
        extract_dir="$WORK_DIR/extract_${RANDOM}"
        mkdir -p "$extract_dir"
        unzip -q "$WORK_DIR/$asset_name" -d "$extract_dir"
        # Per-asset binary_name override, fall back to tool-level binary_name
        asset_binary_name=$(jq -r ".tools[$i].explicit_assets[$j].binary_name // empty" "$CONFIG")
        bin_find="${asset_binary_name:-$binary_name}"
        [[ "$os" == "windows" ]] && bin_find="${bin_find}.exe"
        found=$(find "$extract_dir" -name "$bin_find" -type f | head -1)
        if [[ -z "$found" ]]; then
          echo "  ERROR: binary '$bin_find' not found in $asset_name"
          exit 1
        fi
        cp "$found" "$OUTPUT_DIR/$normalized"
        chmod +x "$OUTPUT_DIR/$normalized"
        rm -rf "$extract_dir"
      fi
      rm -f "$WORK_DIR/$asset_name"

      # Validate the output binary
      if ! validate_binary "$OUTPUT_DIR/$normalized" "$normalized"; then
        rm -f "$OUTPUT_DIR/$normalized"
        exit 1
      fi

      # Append to locked assets array
      locked_assets=$(echo "$locked_assets" | jq \
        --arg up "$asset_name" \
        --arg dl "$download_url" \
        --arg norm "$normalized" \
        --arg os "$os" \
        --arg arch "$arch" \
        --arg variant "$variant" \
        '. + [{upstream: $up, download_url: $dl, normalized: $norm, os: $os, arch: $arch, variant: $variant}]')
    done
  else
    # --- triple_map mode (archive-based tools like rg, bun, uv) ---
    asset_prefix_tpl=$(jq -r ".tools[$i].asset_prefix" "$CONFIG")
    asset_prefix="${asset_prefix_tpl//\{VERSION\}/$clean_version}"

    while IFS= read -r asset_line; do
      asset_name=$(echo "$asset_line" | jq -r '.name')
      download_url=$(echo "$asset_line" | jq -r '.browser_download_url')

      # Determine archive extension
      ext=""
      if [[ "$asset_name" == *.tar.gz ]]; then
        ext=".tar.gz"
      elif [[ "$asset_name" == *.zip ]]; then
        ext=".zip"
      else
        continue
      fi

      # Strip prefix and extension to get the triple
      remainder="${asset_name#"$asset_prefix"}"
      # If stripping didn't change anything, this asset doesn't match our prefix
      if [[ "$remainder" == "$asset_name" ]]; then
        continue
      fi
      triple="${remainder%"$ext"}"

      # Look up triple in triple_map
      platform=$(jq -c ".tools[$i].triple_map[\"$triple\"] // empty" "$CONFIG")
      if [[ -z "$platform" ]]; then
        continue
      fi

      os=$(echo "$platform" | jq -r '.os')
      arch=$(echo "$platform" | jq -r '.arch')
      variant=$(echo "$platform" | jq -r '.variant // empty')

      # Build normalized name
      suffix=""
      [[ "$os" == "windows" ]] && suffix=".exe"
      variant_part=""
      [[ -n "$variant" ]] && variant_part="-${variant}"
      normalized="${name}-${clean_version}-${os}-${arch}${variant_part}${suffix}"

      echo "  $asset_name -> $normalized"

      # Download
      curl -fSL -o "$WORK_DIR/$asset_name" "$download_url"

      # Extract
      extract_dir="$WORK_DIR/extract_${RANDOM}"
      mkdir -p "$extract_dir"
      if [[ "$ext" == ".tar.gz" ]]; then
        tar xzf "$WORK_DIR/$asset_name" -C "$extract_dir"
      elif [[ "$ext" == ".zip" ]]; then
        unzip -q "$WORK_DIR/$asset_name" -d "$extract_dir"
      fi

      # Find the binary
      bin_find="$binary_name"
      [[ "$os" == "windows" ]] && bin_find="${binary_name}.exe"
      found=$(find "$extract_dir" -name "$bin_find" -type f | head -1)
      if [[ -z "$found" ]]; then
        echo "  WARNING: binary '$bin_find' not found in $asset_name, skipping"
        rm -rf "$extract_dir" "${WORK_DIR:?}/$asset_name"
        continue
      fi

      # Copy normalized binary to output
      cp "$found" "$OUTPUT_DIR/$normalized"
      chmod +x "$OUTPUT_DIR/$normalized"
      rm -rf "$extract_dir" "${WORK_DIR:?}/$asset_name"

      # Validate the output binary
      if ! validate_binary "$OUTPUT_DIR/$normalized" "$normalized"; then
        rm -f "$OUTPUT_DIR/$normalized"
        continue
      fi

      # Append to locked assets array
      locked_assets=$(echo "$locked_assets" | jq \
        --arg up "$asset_name" \
        --arg dl "$download_url" \
        --arg norm "$normalized" \
        --arg os "$os" \
        --arg arch "$arch" \
        --arg variant "$variant" \
        '. + [{upstream: $up, download_url: $dl, normalized: $norm, os: $os, arch: $arch, variant: $variant}]')

    done < <(echo "$release" | jq -c '.assets[]')
  fi

  asset_count=$(echo "$locked_assets" | jq 'length')
  echo "  => $asset_count binaries"
  echo

  # Append locked tool to lock structure
  lock_json=$(echo "$lock_json" | jq \
    --arg name "$name" \
    --arg version "$clean_version" \
    --arg tag "$tag" \
    --argjson assets "$locked_assets" \
    '.tools += [{name: $name, version: $version, tag: $tag, assets: $assets}]')
done

# Determine release tag (date-based)
today=$(date -u +%Y-%m-%d)
new_release_tag="$old_release_tag"

if [[ -z "$old_release_tag" ]]; then
  # First run
  new_release_tag="$today"
  echo "Initial release tag: $new_release_tag"
elif [[ -f "$LOCK_FILE" ]]; then
  old_tools_sig=$(jq -r '[.tools[] | "\(.name):\(.version)"] | sort | join(",")' "$LOCK_FILE")
  new_tools_sig=$(echo "$lock_json" | jq -r '[.tools[] | "\(.name):\(.version)"] | sort | join(",")')
  if [[ "$old_tools_sig" != "$new_tools_sig" ]]; then
    new_release_tag="$today"
    echo "Versions changed, new release tag: $old_release_tag -> $new_release_tag"
  else
    echo "No version changes detected, keeping release tag: $new_release_tag"
  fi
fi

# Write lock file
echo "$lock_json" | jq --arg tag "$new_release_tag" '.release_tag = $tag' > "$LOCK_FILE"

# Update README.md with binary listing
README="$SCRIPT_DIR/README.md"
if [[ -f "$README" ]] && grep -q 'BINARIES_START' "$README"; then
  project_url=$(jq -r '.project_url' "$CONFIG")
  release_tag="$new_release_tag"
  release_page="${project_url}/releases/tag/${release_tag}"
  download_base="${project_url}/releases/download/${release_tag}"

  # Build the replacement section
  binaries_section="**Release: [${release_tag}](${release_page})**"$'\n\n'

  num_locked=$(echo "$lock_json" | jq '.tools | length')
  for (( i=0; i<num_locked; i++ )); do
    name=$(echo "$lock_json" | jq -r ".tools[$i].name")
    version=$(echo "$lock_json" | jq -r ".tools[$i].version")

    binaries_section+="### ${name} ${version}"$'\n\n'
    binaries_section+="| File | OS | Arch | Variant | Download |"$'\n'
    binaries_section+="|------|----|------|---------|----------|"$'\n'

    num_assets=$(echo "$lock_json" | jq ".tools[$i].assets | length")
    for (( j=0; j<num_assets; j++ )); do
      norm=$(echo "$lock_json" | jq -r ".tools[$i].assets[$j].normalized")
      os=$(echo "$lock_json" | jq -r ".tools[$i].assets[$j].os")
      arch=$(echo "$lock_json" | jq -r ".tools[$i].assets[$j].arch")
      variant=$(echo "$lock_json" | jq -r ".tools[$i].assets[$j].variant")
      [[ -z "$variant" ]] && variant="-"
      download_link="${download_base}/${norm}"
      binaries_section+="| \`${norm}\` | ${os} | ${arch} | ${variant} | [download](${download_link}) |"$'\n'
    done
    binaries_section+=$'\n'
  done

  # Write section to temp file, then splice into README between markers
  section_file="$WORK_DIR/readme_section.md"
  printf '%s' "$binaries_section" > "$section_file"

  {
    # Print everything up to and including the start marker
    while IFS= read -r line; do
      printf '%s\n' "$line"
      [[ "$line" == *"BINARIES_START"* ]] && break
    done
    # Insert the generated section
    cat "$section_file"
    # Skip old content until end marker, then print the rest
    while IFS= read -r line; do
      if [[ "$line" == *"BINARIES_END"* ]]; then
        printf '%s\n' "$line"
        break
      fi
    done
    # Print everything after the end marker
    cat
  } < "$README" > "$README.tmp" && mv "$README.tmp" "$README"

  echo "Updated README.md with binary listing"
fi

echo "Done. Binaries in ./output/, lock file at binaries.lock.json (${new_release_tag})"
