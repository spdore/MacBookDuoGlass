#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

module_cache="${CLANG_MODULE_CACHE_PATH:-$project_dir/.build/module-cache}"
mkdir -p "$module_cache"
CLANG_MODULE_CACHE_PATH="$module_cache" swift build -c release
bin_dir="$(CLANG_MODULE_CACHE_PATH="$module_cache" swift build -c release --show-bin-path)"
app_dir="$project_dir/dist/MacBookDuoGlass.app"
bundle_id="com.spdor.MacBookDuoGlass"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/MacBookDuoGlass" "$app_dir/Contents/MacOS/MacBookDuoGlass"
cp "$project_dir/AppInfo.plist" "$app_dir/Contents/Info.plist"

chmod +x "$app_dir/Contents/MacOS/MacBookDuoGlass"
# The Swift linker gives the executable an ad-hoc signature whose identifier is
# the executable name. Sign the finished bundle explicitly so its code identity
# matches CFBundleIdentifier and the Info.plist is sealed into the signature.
# A real identity can be supplied through CODE_SIGN_IDENTITY when one is
# available; the ad-hoc fallback still carries the same explicit designated
# requirement, so macOS can bind the permission to this bundle identity.
signing_identity="${CODE_SIGN_IDENTITY:--}"
codesign --force --deep --sign "$signing_identity" \
  --identifier "$bundle_id" \
  --requirements "=designated => identifier \"$bundle_id\"" \
  --timestamp=none "$app_dir"
printf 'Built %s\n' "$app_dir"
