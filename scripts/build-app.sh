#!/bin/bash
#
# Builds CalPilot and assembles dist/CalPilot.app.
#
# The bundle is not cosmetic: macOS TCC attributes calendar permission to a bundle
# identifier, and a bare command-line binary has no stable identity, so it either
# gets no prompt or loses its grant on the next rebuild.
#
# Usage:
#   scripts/build-app.sh              # build + assemble, unsigned (best for rebuilds)
#   scripts/build-app.sh --sign       # additionally ad-hoc codesign the bundle
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${CALPILOT_BUILD_DIR:-$ROOT/.build}"
APP="$ROOT/dist/CalPilot.app"
BUNDLE_ID="${CALPILOT_BUNDLE_ID:-com.calpilot.cli}"

SIGN=0
for arg in "$@"; do
  case "$arg" in
    --sign) SIGN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "==> building release binary"
swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH"
BIN="$SCRATCH/release/calpilot"
test -x "$BIN" || { echo "build produced no binary at $BIN" >&2; exit 1; }

echo "==> assembling $APP"
if [[ -d "$APP" ]]; then
  # Only ever remove the exact bundle we are about to recreate.
  rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CalPilot"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>CalPilot</string>
  <key>CFBundleDisplayName</key>
  <string>CalPilot</string>
  <key>CFBundleExecutable</key>
  <string>CalPilot</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>CalPilot reads your existing events and writes the plans you approve into its own calendar.</string>
  <key>NSCalendarsWriteOnlyAccessUsageDescription</key>
  <string>CalPilot writes the plans you approve into its own calendar.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>CalPilot reads your existing events so it can find free time and avoid double-booking you.</string>
  <key>NSHumanReadableCopyright</key>
  <string>CalPilot</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# A launcher keeps the CLI ergonomic without giving up the bundle identity.
# The path is resolved at runtime so the whole tree stays relocatable.
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/calpilot" <<'LAUNCH'
#!/bin/bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/dist/CalPilot.app/Contents/MacOS/CalPilot" "$@"
LAUNCH
chmod +x "$ROOT/bin/calpilot"

if [[ "$SIGN" == "1" ]]; then
  echo "==> ad-hoc signing"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  codesign --verify --verbose "$APP" 2>&1 | tail -3
else
  echo "==> left unsigned (TCC keeps matching this path across rebuilds)"
fi

cat <<DONE

Done.
  bundle : $APP
  launch : $ROOT/bin/calpilot

Next:
  $ROOT/bin/calpilot doctor
DONE
