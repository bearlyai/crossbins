#!/usr/bin/env bash
set -euo pipefail

# Sign macOS binaries and app-bundle archives in ./output/ with Bearly's
# Developer ID Application certificate. App bundles are also submitted to Apple
# notarization and stapled before they are repacked.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
CACHE_DIR="$SCRIPT_DIR/.cache"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

decode_base64_to_file() {
  local output="$1"
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    base64 --decode > "$output"
  else
    base64 -D > "$output"
  fi
}

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: sign-macos.sh must run on macOS because codesign/notarytool are required." >&2
    exit 1
  fi
}

install_certificate() {
  : "${CSC_LINK:?Set CSC_LINK to the Bearly Developer ID certificate p12/base64}"
  : "${CSC_KEY_PASSWORD:?Set CSC_KEY_PASSWORD for the Developer ID certificate}"

  mkdir -p "$CACHE_DIR"
  CERT_PATH="$CACHE_DIR/macos-signing-cert.p12"
  KEYCHAIN_PATH="$CACHE_DIR/crossbins-signing.keychain-db"
  KEYCHAIN_PASSWORD="${MACOS_KEYCHAIN_PASSWORD:-crossbins-signing}"

  if [[ "$CSC_LINK" == http://* || "$CSC_LINK" == https://* ]]; then
    curl -fSL -o "$CERT_PATH" "$CSC_LINK"
  elif [[ "$CSC_LINK" == file://* ]]; then
    cp "${CSC_LINK#file://}" "$CERT_PATH"
  elif [[ -f "$CSC_LINK" ]]; then
    cp "$CSC_LINK" "$CERT_PATH"
  else
    cert_payload="${CSC_LINK#data:application/x-pkcs12;base64,}"
    cert_payload="${cert_payload#data:application/octet-stream;base64,}"
    printf '%s' "$cert_payload" | decode_base64_to_file "$CERT_PATH"
  fi

  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security import "$CERT_PATH" -k "$KEYCHAIN_PATH" -P "$CSC_KEY_PASSWORD" -T /usr/bin/codesign -T /usr/bin/productsign
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

  SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:-}"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | awk -F '"' '/Developer ID Application/ { print $2; exit }')
  fi
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "ERROR: no Developer ID Application identity found in imported certificate" >&2
    exit 1
  fi
  echo "sign-macos: using identity: $SIGNING_IDENTITY"
}

is_macho() {
  local filepath="$1"
  file "$filepath" | grep -q 'Mach-O'
}

sign_binary() {
  local filepath="$1"
  if ! is_macho "$filepath"; then
    echo "sign-macos: skipping non-Mach-O $(basename "$filepath")"
    return
  fi
  codesign --force --timestamp --options runtime --keychain "$KEYCHAIN_PATH" --sign "$SIGNING_IDENTITY" "$filepath"
  codesign --verify --strict --verbose=2 "$filepath"
}

sign_and_notarize_app() {
  local app_path="$1"
  : "${APPLEID:?Set APPLEID for notarization}"
  : "${APPLEIDPASSWORD:?Set APPLEIDPASSWORD for notarization}"
  : "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID for notarization}"

  codesign --force --deep --timestamp --options runtime --keychain "$KEYCHAIN_PATH" --sign "$SIGNING_IDENTITY" "$app_path"
  codesign --verify --deep --strict --verbose=2 "$app_path"

  local zip_path
  zip_path="$CACHE_DIR/notary-$(uuidgen).zip"
  ditto -c -k --keepParent "$app_path" "$zip_path"
  xcrun notarytool submit "$zip_path" \
    --apple-id "$APPLEID" \
    --password "$APPLEIDPASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
  rm -f "$zip_path"
  xcrun stapler staple "$app_path"
  codesign --verify --deep --strict --verbose=2 "$app_path"
}

sign_archive() {
  local archive_path="$1" entry
  local temp_dir
  local top_level_entries=()
  temp_dir="$(mktemp -d)"
  tar xzf "$archive_path" -C "$temp_dir"

  while IFS= read -r executable; do
    sign_binary "$executable"
  done < <(find "$temp_dir" -type f -perm -111 | sort)

  while IFS= read -r app_path; do
    sign_and_notarize_app "$app_path"
  done < <(find "$temp_dir" -type d -name '*.app' | sort)

  rm -f "$archive_path"
  while IFS= read -r -d '' entry; do
    top_level_entries+=("$(basename "$entry")")
  done < <(find "$temp_dir" -mindepth 1 -maxdepth 1 -print0)
  if [[ "${#top_level_entries[@]}" -eq 0 ]]; then
    echo "ERROR: $archive_path is empty after extraction" >&2
    rm -rf "$temp_dir"
    exit 1
  fi
  (cd "$temp_dir" && COPYFILE_DISABLE=1 tar czf "$archive_path" "${top_level_entries[@]}")
  rm -rf "$temp_dir"
  echo "sign-macos: repacked $(basename "$archive_path") ($(sha256_file "$archive_path"))"
}

require_macos
install_certificate

macos_assets=()
while IFS= read -r f; do
  macos_assets+=("$f")
done < <(find "$OUTPUT_DIR" -maxdepth 1 -type f \( -name '*-darwin-*' -o -name '*-macos-*' \) | sort)

if [[ "${#macos_assets[@]}" -eq 0 ]]; then
  echo "sign-macos: no macOS assets in output/ - nothing to sign."
  exit 0
fi

echo "sign-macos: ${#macos_assets[@]} macOS assets to sign:"
printf '  %s\n' "${macos_assets[@]##*/}"

for asset in "${macos_assets[@]}"; do
  case "$asset" in
    *.tar.gz) sign_archive "$asset" ;;
    *) sign_binary "$asset" ;;
  esac
done

echo "sign-macos: done."
