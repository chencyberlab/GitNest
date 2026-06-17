#!/usr/bin/env bash
# Build GitNest into a double-clickable .app bundle (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="GitNest"
DISPLAY_NAME="GitNest"
BUNDLE="${APP_NAME}.app"
CONFIG="release"
VERSION="1.0.0"
BUILD_NUMBER="1"
BUILD_ARCH="${BUILD_ARCH:-native}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-local.${APP_NAME}}"

# Build into a scratch dir OUTSIDE iCloud (~/Desktop is iCloud-synced, and SQLite
# build.db locking fails there with "disk I/O error"). ~/Library/Caches is local.
SCRATCH="${SCRATCH_PATH:-$HOME/Library/Caches/GitNest}"

case "$BUILD_ARCH" in
  native)
    BUILD_ARGS=(-c "$CONFIG" --scratch-path "$SCRATCH")
    BIN="${SCRATCH}/${CONFIG}/${APP_NAME}"
    ;;
  arm64|x86_64)
    BUILD_ARGS=(-c "$CONFIG" --arch "$BUILD_ARCH" --scratch-path "$SCRATCH")
    BIN="${SCRATCH}/${BUILD_ARCH}-apple-macosx/${CONFIG}/${APP_NAME}"
    ;;
  universal)
    BUILD_ARGS=(-c "$CONFIG" --arch arm64 --arch x86_64 --scratch-path "$SCRATCH")
    BIN="${SCRATCH}/apple/Products/Release/${APP_NAME}"
    ;;
  *)
    echo "ERROR: BUILD_ARCH must be one of: native, arm64, x86_64, universal" >&2
    exit 1
    ;;
esac

echo ">> Compiling ($CONFIG, $BUILD_ARCH) into $SCRATCH ..."
swift build "${BUILD_ARGS[@]}"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: expected binary not found at $BIN" >&2
  exit 1
fi

echo ">> Assembling ${BUNDLE} ..."
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "$BIN" "${BUNDLE}/Contents/MacOS/${APP_NAME}"

# Pin GitHub's SSH host keys so SSH checks are strict instead of accept-new.
KNOWN_HOSTS="Resources/known_hosts"
if [[ -f "$KNOWN_HOSTS" ]]; then
  cp "$KNOWN_HOSTS" "${BUNDLE}/Contents/Resources/known_hosts"
  echo "   bundled $KNOWN_HOSTS"
else
  # Fail loud rather than ship a build whose SSH checks silently fall back to the
  # user's ~/.ssh/known_hosts (no host-key pinning). The file is committed, so a
  # missing one is an anomaly worth stopping for.
  echo "ERROR: $KNOWN_HOSTS not found — refusing to ship an unpinned build." >&2
  echo "       Regenerate it from GitHub's published keys (HTTPS-validated, not TOFU):" >&2
  echo "         curl -fsSL https://api.github.com/meta | jq -r '.ssh_keys[] | \"github.com \" + .' > $KNOWN_HOSTS" >&2
  exit 1
fi

ICON_PLIST_ENTRY=""
if [[ -f "AppIcon.icns" ]]; then
  cp "AppIcon.icns" "${BUNDLE}/Contents/Resources/AppIcon.icns"
  ICON_PLIST_ENTRY='  <key>CFBundleIconFile</key><string>AppIcon</string>'
  echo "   bundled AppIcon.icns"
else
  echo "   (no AppIcon.icns yet - render gitnest-icon.svg to AppIcon.icns)"
fi

cat > "${BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_IDENTIFIER}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
${ICON_PLIST_ENTRY}
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature WITH Hardened Runtime (--options runtime). This needs no paid
# Developer ID and restricts other user-level processes from attaching a debugger
# or reading this process's memory — i.e. lifting SSH key material or the agent
# handle out of GitNest at runtime. If a hardened-runtime ad-hoc bundle ever fails
# to launch on some setup, drop `--options runtime` to fall back to a plain ad-hoc
# signature.
echo ">> Ad-hoc codesigning (Hardened Runtime) ..."
codesign --force --deep --options runtime --sign - "$BUNDLE" >/dev/null 2>&1 || echo "   (codesign skipped - not required to run locally)"

echo "OK: built ./${BUNDLE}"
echo "    Architecture: $(lipo -archs "${BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || uname -m)"
echo "    Run with:  open ./${BUNDLE}     (or double-click it in Finder)"
