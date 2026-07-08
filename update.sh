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

sha256_file() {
  local filepath="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$filepath" | awk '{print $1}'
  else
    shasum -a 256 "$filepath" | awk '{print $1}'
  fi
}

append_locked_asset() {
  local locked="$1" upstream="$2" download_url="$3" normalized="$4"
  local os="$5" arch="$6" variant="$7" source_sha256="$8" output_sha256="$9"

  echo "$locked" | jq \
    --arg up "$upstream" \
    --arg dl "$download_url" \
    --arg norm "$normalized" \
    --arg os "$os" \
    --arg arch "$arch" \
    --arg variant "$variant" \
    --arg source_sha256 "$source_sha256" \
    --arg output_sha256 "$output_sha256" \
    '. + [({upstream: $up, download_url: $dl, normalized: $norm, os: $os, arch: $arch, variant: $variant}
      + (if $source_sha256 != "" then {source_sha256: $source_sha256} else {} end)
      + (if $output_sha256 != "" then {sha256: $output_sha256} else {} end))]'
}

verify_checksum() {
  local checksum_file="$1" asset_name="$2" filepath="$3"
  local expected actual

  expected=$(awk -v asset="$asset_name" '$2 == asset { print $1; found=1; exit } END { if (!found) exit 1 }' "$checksum_file" || true)
  if [[ -z "$expected" ]]; then
    echo "  ERROR: checksum for $asset_name not found in $(basename "$checksum_file")" >&2
    return 1
  fi

  actual=$(sha256_file "$filepath")
  if [[ "$actual" != "$expected" ]]; then
    echo "  ERROR: checksum mismatch for $asset_name" >&2
    echo "    expected: $expected" >&2
    echo "    actual:   $actual" >&2
    return 1
  fi

  printf '%s' "$expected"
}

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

validate_archive() {
  local filepath="$1" name="$2" source_type="$3"

  if ! validate_binary "$filepath" "$name"; then
    return 1
  fi

  if [[ "$source_type" == "zip" ]]; then
    unzip -tq "$filepath" >/dev/null
  elif [[ "$source_type" == "tar.gz" ]]; then
    tar tzf "$filepath" >/dev/null
  elif [[ "$source_type" == "tar.xz" ]]; then
    tar tJf "$filepath" >/dev/null
  else
    echo "  ERROR: unsupported preserved archive type '$source_type' for $name"
    return 1
  fi
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
  release_tag_pattern=$(jq -r ".tools[$i].release_tag_pattern // empty" "$CONFIG")
  include_prereleases=$(jq -r ".tools[$i].include_prereleases // false" "$CONFIG")
  version_probe_regex=$(jq -r ".tools[$i].version_probe_regex // empty" "$CONFIG")
  checksum_asset=$(jq -r ".tools[$i].checksum_asset // empty" "$CONFIG")

  # Fetch latest stable release (first non-draft, non-prerelease)
  releases_json=$(curl -sfL "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
    "https://api.github.com/repos/$repo/releases?per_page=100")

  if [[ -n "$release_tag_pattern" ]]; then
    release=$(echo "$releases_json" | jq -e --arg re "$release_tag_pattern" --argjson include_prereleases "$include_prereleases" \
      'map(select(.draft == false and ($include_prereleases or .prerelease == false) and (.tag_name | test($re)))) | first')
  else
    release=$(echo "$releases_json" | jq -e --argjson include_prereleases "$include_prereleases" \
      'map(select(.draft == false and ($include_prereleases or .prerelease == false))) | first')
  fi
  tag=$(echo "$release" | jq -r '.tag_name')

  # Clean version: strip leading "v", "bun-v", etc.
  if [[ -n "$version_probe_regex" ]]; then
    clean_version=$(echo "$release" | jq -r --arg re "$version_probe_regex" '
      def version_key: split(".") | map(tonumber? // 0);
      [.assets[].name | capture($re)? | .version] | unique | sort_by(version_key) | last // empty
    ')
    if [[ -z "$clean_version" ]]; then
      echo "  ERROR: could not resolve version with version_probe_regex for $name"
      exit 1
    fi
  else
    clean_version="$tag"
    clean_version="${clean_version#bun-v}"
    clean_version="${clean_version#v}"
  fi

  echo "=== $name: version $clean_version (tag: $tag) ==="

  locked_assets="[]"
  checksum_file=""
  if [[ -n "$checksum_asset" ]]; then
    checksum_url=$(echo "$release" | jq -r \
      --arg name "$checksum_asset" '.assets[] | select(.name == $name) | .browser_download_url')
    if [[ -z "$checksum_url" ]]; then
      echo "  ERROR: checksum asset '$checksum_asset' not found in release $tag"
      exit 1
    fi
    checksum_file="$WORK_DIR/${name}_${checksum_asset}"
    curl -fSL -o "$checksum_file" "$checksum_url"
  fi

  # Check if tool uses explicit_assets mode
  has_explicit=$(jq -r ".tools[$i].explicit_assets // empty" "$CONFIG")

  if [[ -n "$has_explicit" ]]; then
    # --- explicit_assets mode (for tools like yt-dlp with non-standard naming) ---
    num_explicit=$(jq ".tools[$i].explicit_assets | length" "$CONFIG")
    for (( j=0; j<num_explicit; j++ )); do
      asset_name_tpl=$(jq -r ".tools[$i].explicit_assets[$j].asset_name // empty" "$CONFIG")
      asset_regex_tpl=$(jq -r ".tools[$i].explicit_assets[$j].asset_regex // empty" "$CONFIG")
      asset_url_tpl=$(jq -r ".tools[$i].explicit_assets[$j].url // empty" "$CONFIG")
      checksum_url_tpl=$(jq -r ".tools[$i].explicit_assets[$j].checksum_url // empty" "$CONFIG")
      checksum_name=$(jq -r ".tools[$i].explicit_assets[$j].checksum_name // empty" "$CONFIG")
      version_check_regex_tpl=$(jq -r ".tools[$i].explicit_assets[$j].version_check_regex // empty" "$CONFIG")
      preserve_archive=$(jq -r ".tools[$i].explicit_assets[$j].preserve_archive // false" "$CONFIG")
      output_extension=$(jq -r ".tools[$i].explicit_assets[$j].output_extension // empty" "$CONFIG")
      macos_app_rewrap=$(jq -c ".tools[$i].explicit_assets[$j].macos_app_rewrap // empty" "$CONFIG")
      is_direct=0
      downloaded_file=""

      if [[ -n "$asset_url_tpl" ]]; then
        is_direct=1
        download_url="${asset_url_tpl//\{VERSION\}/$clean_version}"
        asset_name=""
      elif [[ -n "$asset_regex_tpl" ]]; then
        asset_regex="${asset_regex_tpl//\{VERSION\}/$clean_version}"
        asset_name=$(echo "$release" | jq -r --arg re "$asset_regex" \
          '[.assets[].name | select(test($re))] | sort | last // empty')
        if [[ -z "$asset_name" ]]; then
          echo "  ERROR: no asset matched regex '$asset_regex' in release $tag"
          exit 1
        fi
      else
        asset_name="${asset_name_tpl//\{VERSION\}/$clean_version}"
      fi
      source_type=$(jq -r ".tools[$i].explicit_assets[$j].source_type" "$CONFIG")
      os=$(jq -r ".tools[$i].explicit_assets[$j].os" "$CONFIG")
      arch=$(jq -r ".tools[$i].explicit_assets[$j].arch" "$CONFIG")
      variant=$(jq -r ".tools[$i].explicit_assets[$j].variant // empty" "$CONFIG")

      if [[ "$is_direct" -eq 0 ]]; then
        # Find this asset in the release — fail hard if missing
        download_url=$(echo "$release" | jq -r \
          --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url')
        if [[ -z "$download_url" ]]; then
          echo "  ERROR: expected asset '$asset_name' not found in release $tag"
          exit 1
        fi
      fi

      # Build normalized name
      suffix="$output_extension"
      [[ -z "$suffix" && "$os" == "windows" ]] && suffix=".exe"
      variant_part=""
      [[ -n "$variant" ]] && variant_part="-${variant}"
      normalized="${name}-${clean_version}-${os}-${arch}${variant_part}${suffix}"

      # Download
      if [[ "$is_direct" -eq 1 ]]; then
        downloaded_file="$WORK_DIR/direct_${name}_${j}"
        effective_url=$(curl -fL -w '%{url_effective}' -o "$downloaded_file" "$download_url")
        download_url="$effective_url"
        asset_name=$(basename "${effective_url%%\?*}")
        if [[ -z "$checksum_name" ]]; then
          checksum_name="$asset_name"
        fi
        if [[ -n "$version_check_regex_tpl" ]]; then
          version_check_regex="${version_check_regex_tpl//\{VERSION\}/$clean_version}"
          if ! [[ "$download_url" =~ $version_check_regex ]]; then
            echo "  ERROR: direct asset URL '$download_url' did not match version_check_regex '$version_check_regex'"
            exit 1
          fi
        fi
      else
        downloaded_file="$WORK_DIR/$asset_name"
        curl -fSL -o "$downloaded_file" "$download_url"
      fi

      echo "  $asset_name -> $normalized"

      expected_sha256=""
      if [[ "$is_direct" -eq 1 && -n "$checksum_url_tpl" ]]; then
        direct_checksum_url="${checksum_url_tpl//\{EFFECTIVE_URL\}/$download_url}"
        direct_checksum_url="${direct_checksum_url//\{VERSION\}/$clean_version}"
        direct_checksum_file="$WORK_DIR/direct_${name}_${j}.sha256"
        curl -fSL -o "$direct_checksum_file" "$direct_checksum_url"
        expected_sha256=$(verify_checksum "$direct_checksum_file" "$checksum_name" "$downloaded_file")
      elif [[ -n "$checksum_file" ]]; then
        expected_sha256=$(verify_checksum "$checksum_file" "$asset_name" "$downloaded_file")
      fi

      if [[ "$preserve_archive" == "true" ]]; then
        if [[ -z "$output_extension" ]]; then
          echo "  ERROR: preserve_archive requires output_extension for $asset_name"
          exit 1
        fi
        if [[ -n "$macos_app_rewrap" ]]; then
          source_app_name=$(echo "$macos_app_rewrap" | jq -r '.source_app_name')
          app_name=$(echo "$macos_app_rewrap" | jq -r '.app_name')
          bundle_id=$(echo "$macos_app_rewrap" | jq -r '.bundle_id')
          display_name=$(echo "$macos_app_rewrap" | jq -r '.display_name')
          archive_root_tpl=$(echo "$macos_app_rewrap" | jq -r '.archive_root')
          archive_root="${archive_root_tpl//\{VERSION\}/$clean_version}"
          license_file=$(echo "$macos_app_rewrap" | jq -r '.license_file')
          root_binary_name=$(echo "$macos_app_rewrap" | jq -r '.root_binary_name // empty')
          python3 "$SCRIPT_DIR/rewrap-macos-app.py" \
            --archive "$downloaded_file" \
            --output "$OUTPUT_DIR/$normalized" \
            --source-app-name "$source_app_name" \
            --app-name "$app_name" \
            --bundle-id "$bundle_id" \
            --display-name "$display_name" \
            --version "$clean_version" \
            --archive-root "$archive_root" \
            --license-file "$SCRIPT_DIR/$license_file" \
            --root-binary-name "$root_binary_name"
        else
          cp "$downloaded_file" "$OUTPUT_DIR/$normalized"
        fi
      elif [[ "$source_type" == "raw" ]]; then
        # Raw binary — just copy directly
        cp "$downloaded_file" "$OUTPUT_DIR/$normalized"
        chmod +x "$OUTPUT_DIR/$normalized"
      elif [[ "$source_type" == "zip" || "$source_type" == "tar.gz" || "$source_type" == "tar.xz" ]]; then
        # Archive — extract and find binary
        extract_dir="$WORK_DIR/extract_${RANDOM}"
        mkdir -p "$extract_dir"
        if [[ "$source_type" == "zip" ]]; then
          unzip -q "$downloaded_file" -d "$extract_dir"
        elif [[ "$source_type" == "tar.gz" ]]; then
          tar xzf "$downloaded_file" -C "$extract_dir"
        elif [[ "$source_type" == "tar.xz" ]]; then
          tar xJf "$downloaded_file" -C "$extract_dir"
        fi
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
      else
        echo "  ERROR: unsupported source_type '$source_type' for $asset_name"
        exit 1
      fi
      rm -f "$downloaded_file"

      # Validate the output artifact
      if [[ "$preserve_archive" == "true" ]]; then
        if validate_archive "$OUTPUT_DIR/$normalized" "$normalized" "$source_type"; then
          validation_status=0
        else
          validation_status=1
        fi
      elif validate_binary "$OUTPUT_DIR/$normalized" "$normalized"; then
        validation_status=0
      else
        validation_status=1
      fi
      if [[ "$validation_status" -ne 0 ]]; then
        rm -f "$OUTPUT_DIR/$normalized"
        exit 1
      fi
      output_sha256=$(sha256_file "$OUTPUT_DIR/$normalized")

      # Append to locked assets array
      locked_assets=$(append_locked_asset "$locked_assets" "$asset_name" "$download_url" "$normalized" "$os" "$arch" "$variant" "$expected_sha256" "$output_sha256")
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
      elif [[ "$asset_name" == *.tar.xz ]]; then
        ext=".tar.xz"
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

      expected_sha256=""
      if [[ -n "$checksum_file" ]]; then
        expected_sha256=$(verify_checksum "$checksum_file" "$asset_name" "$WORK_DIR/$asset_name")
      fi

      # Extract
      extract_dir="$WORK_DIR/extract_${RANDOM}"
      mkdir -p "$extract_dir"
      if [[ "$ext" == ".tar.gz" ]]; then
        tar xzf "$WORK_DIR/$asset_name" -C "$extract_dir"
      elif [[ "$ext" == ".tar.xz" ]]; then
        tar xJf "$WORK_DIR/$asset_name" -C "$extract_dir"
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
      output_sha256=$(sha256_file "$OUTPUT_DIR/$normalized")

      # Append to locked assets array
      locked_assets=$(append_locked_asset "$locked_assets" "$asset_name" "$download_url" "$normalized" "$os" "$arch" "$variant" "$expected_sha256" "$output_sha256")

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
  old_tools_sig=$(jq -c '[.tools[] | {name, version, tag, assets: [.assets[] | {upstream, normalized, source_sha256: (.source_sha256 // ""), sha256: (.sha256 // "")}]}] | sort_by(.name)' "$LOCK_FILE")
  new_tools_sig=$(echo "$lock_json" | jq -c '[.tools[] | {name, version, tag, assets: [.assets[] | {upstream, normalized, source_sha256: (.source_sha256 // ""), sha256: (.sha256 // "")}]}] | sort_by(.name)')
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
