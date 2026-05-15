#!/usr/bin/env bash
set -euo pipefail

REPO_URL=https://lbschenkel.github.io/flatpaks/repo/
REPO_KEY=FE37AF86681F953BBBFDEE920776E3BC6B5F8E4C

REPO_DIR="${1:-docs/repo}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SOURCES=(
  "lbschenkel/free42-flatpak"
  "lbschenkel/plus42-flatpak"
  "lbschenkel/remotemaster-flatpak"
  "lbschenkel/irscrutinizer-flatpak"
)

mkdir -p "$REPO_DIR"
if [[ ! -d "$REPO_DIR/objects" ]]; then
  echo "Initializing Flatpak OSTree repo in $REPO_DIR"
  ostree init --repo="$REPO_DIR" --mode=archive-z2
fi

auth_headers=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  auth_headers=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

if [ -f "$REPO_KEY.asc" ] && gpg --list-secret-keys "$REPO_KEY" > /dev/null 2>&1;
then
  SIGN_ARGS="--gpg-sign=$REPO_KEY"
  VERIFY_ARGS="--gpg-file=$REPO_KEY.asc"
  key=$(gpg --dearmor < $REPO_KEY.asc | base64 -w0) \
    && gawk -i inplace -v key="$key" '/^GPGKey=/{print "GPGKey=" key; next} {print}' docs/lbschenkel.flatpakrepo

  echo Signing with GPG key: $REPO_KEY
else
  SIGN_ARGS=""
  VERIFY_ARGS=""

  echo -e 'WARNING: Building *without* signing!\a'
  sleep 5
fi
echo

imported=0

for source in "${SOURCES[@]}"; do
  echo "Checking latest release for $source"
  api_url="https://api.github.com/repos/$source/releases/latest"

  release_json="$(curl -fsSL "${auth_headers[@]}" -H "Accept: application/vnd.github+json" "$api_url")"

  mapfile -t bundle_urls < <(
    echo "$release_json" | jq -r '.assets[]? | select(.name | endswith(".flatpak")) | .browser_download_url'
  )

  if [[ ${#bundle_urls[@]} -eq 0 ]]; then
    echo "No .flatpak assets found in latest release for $source"
    continue
  fi

  for url in "${bundle_urls[@]}"; do
    filename="$(basename "$url")"
    local_path="$TMP_DIR/${source//\//__}__${filename}"

    echo "Downloading $filename"
    curl -fsSL "${auth_headers[@]}" -H "Accept: application/octet-stream" -L "$url" -o "$local_path"

    echo "Importing $filename"
    flatpak build-import-bundle $SIGN_ARGS "$REPO_DIR" "$local_path"
    imported=$((imported + 1))
  done
done

if [[ $imported -eq 0 ]]; then
  echo "No bundles imported; skipping metadata update"
  exit 0
fi

echo "Updating repository metadata"
flatpak build-update-repo $SIGN_ARGS \
  --generate-static-deltas --prune \
  "$REPO_DIR" 

echo "Committing changes"
git add -A "$REPO_DIR"
git commit --amend -m "Updated repo"

echo "Done. Imported $imported bundle(s) into $REPO_DIR"

