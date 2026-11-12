#!/usr/bin/env bash
# Builds a release and packs it for itch.io: build/dist/loot-silo-<os>-<version>.zip
#
#   tool/package.sh            # Linux, on Linux
#   bash tool/package.sh       # Windows, in Git Bash (needs Visual Studio C++)
#   tool/package.sh            # macOS, on macOS (needs Xcode); universal app
#
# The zip has the app, its libraries and an .itch.toml at its root (no
# wrapper folder); the manifest tells the itch desktop app what to launch.
set -euo pipefail

cd "$(dirname "$0")/.."
FLUTTER="${FLUTTER:-flutter}"
command -v "$FLUTTER" >/dev/null || FLUTTER="$HOME/development/flutter/bin/flutter"

VERSION="$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)"
case "$(uname -s)" in
  Linux*) OS=linux ;;
  Darwin*) OS=macos ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

NAME="loot-silo-$OS-$VERSION"
DIST="build/dist"
STAGE="$DIST/$NAME"

"$FLUTTER" build "$OS" --release

rm -rf "$STAGE" "$DIST/$NAME.zip"
mkdir -p "$STAGE"

if [ "$OS" = linux ]; then
  cp -r build/linux/x64/release/bundle/. "$STAGE/"
  # share/ is only for a system-wide install; the app registers its own
  # desktop entry (~/.local/share/applications) on first launch.
  rm -rf "$STAGE/share"
  EXE=loot_silo
elif [ "$OS" = macos ]; then
  # Ad-hoc signed by the build (no Developer ID), so not notarized.
  cp -R "build/macos/Build/Products/Release/Loot Silo.app" "$STAGE/"
  EXE="Loot Silo.app"
  cat > "$STAGE/README-macOS.txt" <<'EOF'
Loot Silo for macOS (Apple Silicon and Intel, macOS 12 or later)

Installed with the itch.io app: just press Launch.

Downloaded with a browser: the app is not notarized by Apple, so macOS
blocks the first launch ("can't be opened" or "is damaged"). Move
Loot Silo.app to Applications, then either
  - right-click it > Open > Open (macOS 14 and older), or
  - System Settings > Privacy & Security > Open Anyway (macOS 15+), or
  - in Terminal: xattr -dr com.apple.quarantine "/Applications/Loot Silo.app"

macOS may ask to let Loot Silo use your keychain (where the itch.io API
key is stored); choose Always Allow. It can ask again after an update.
EOF
else
  cp -r build/windows/x64/runner/Release/. "$STAGE/"
  # The Visual C++ runtime, so the app starts on PCs that lack it.
  for dll in msvcp140.dll vcruntime140.dll vcruntime140_1.dll; do
    src="${SYSTEMROOT:-C:/Windows}/System32/$dll"
    [ -f "$src" ] && cp "$src" "$STAGE/"
  done
  EXE=loot_silo.exe
fi

cat > "$STAGE/.itch.toml" <<EOF
[[actions]]
name = "Loot Silo"
path = "$EXE"
EOF

cp LICENSE "$STAGE/LICENSE.txt"

# Zip the folder's contents, not the folder: itch reads .itch.toml only
# from the root of the upload.
(cd "$STAGE" && if [ "$OS" = macos ]; then
  # ditto keeps the bundle's symlinks, permissions and signature intact.
  ditto -c -k --norsrc --noextattr --noacl . "../$NAME.zip"
elif command -v zip >/dev/null; then
  zip -qr -y "../$NAME.zip" .
else
  # Windows' own bsdtar (not Git Bash's GNU tar) writes zips.
  "${SYSTEMROOT:-C:/Windows}/System32/tar.exe" -a -cf "../$NAME.zip" .
fi)

echo "Packed $DIST/$NAME.zip"
