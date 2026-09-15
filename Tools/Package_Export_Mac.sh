#!/usr/bin/env bash
set -euo pipefail

# Copies the pieces Godot's own export step deliberately leaves out - the
# llama-server engine (macOS/Apple Silicon build), the fine-tuned model, and
# the Llama 3.2 license notice - into an already-exported macOS .app bundle.
#
# Tools/llama-server-macos/ and Models/AI/ both have a .gdignore marker, so
# the Godot editor never scans, imports, or exports them (see
# Tools/llama-server-macos-README.md and Models/AI/README.md). Godot's
# export step never copies them anywhere on its own - that's deliberate, see
# Tools/Package_Export.ps1 (the Windows equivalent of this script) for the
# full reasoning. This is the Mac half of that same idea.
#
# Run this on an actual Mac, after exporting the game from Godot as a ZIP
# (see claude/mac-support-howto-export-and-test.md) and unzipping it. It
# needs to run on a Mac because it edits a macOS .app bundle in place and
# re-applies a code signature - neither is something Windows can do.
#
# Usage:
#   ./Tools/Package_Export_Mac.sh [path to the exported .app]
#
# Defaults to builds/macos/ArchibaldManorMystery.app under the project root
# if no path is given.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="${1:-$PROJECT_ROOT/builds/macos/ArchibaldManorMystery.app}"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: no .app bundle found at $APP_BUNDLE" >&2
    echo "" >&2
    echo "Export the game from the Godot editor first (Project > Export... >" >&2
    echo "macOS > Export Project, saved as a .zip, then unzip it), or pass the" >&2
    echo "path to your .app as an argument:" >&2
    echo "  ./Tools/Package_Export_Mac.sh /path/to/ArchibaldManorMystery.app" >&2
    exit 1
fi

MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
if [ ! -d "$MACOS_DIR" ]; then
    echo "Error: $APP_BUNDLE doesn't look like a real .app bundle (no Contents/MacOS inside it)." >&2
    exit 1
fi

ENGINE_SOURCE="$PROJECT_ROOT/Tools/llama-server-macos"
MODEL_SOURCE="$PROJECT_ROOT/Models/AI/archibald-basev2.1.gguf"
NOTICE_SOURCE="$PROJECT_ROOT/Models/AI/NOTICE.txt"

if [ ! -d "$ENGINE_SOURCE" ]; then
    echo "Error: missing $ENGINE_SOURCE - see Tools/llama-server-macos-README.md to download it first." >&2
    exit 1
fi
if [ ! -f "$MODEL_SOURCE" ]; then
    echo "Error: missing $MODEL_SOURCE - see Models/AI/README.md to download it first." >&2
    exit 1
fi

echo "Copying llama-server engine..."
rm -rf "$MACOS_DIR/Tools/llama-server-macos"
mkdir -p "$MACOS_DIR/Tools"
cp -R "$ENGINE_SOURCE" "$MACOS_DIR/Tools/llama-server-macos"
chmod +x "$MACOS_DIR/Tools/llama-server-macos/llama-server"

echo "Copying model weights (this is the 2+ GB file, it may take a moment)..."
mkdir -p "$MACOS_DIR/Models/AI"
cp "$MODEL_SOURCE" "$MACOS_DIR/Models/AI/archibald-basev2.1.gguf"

echo "Copying the Llama 3.2 license notice..."
cp "$NOTICE_SOURCE" "$MACOS_DIR/NOTICE.txt"

echo "Re-applying an ad-hoc signature (bundle contents changed since Godot's own export)..."
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep -s - "$APP_BUNDLE" || echo "  codesign ran but reported a problem - the app may still run; see the notes below."
else
    echo "  codesign not found (are you running this on an actual Mac?) - skipped."
fi

echo "Clearing the quarantine flag for local testing..."
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

echo ""
echo "Done. $APP_BUNDLE now has everything the exported game needs:"
echo "  - Contents/MacOS/Tools/llama-server-macos/  (the engine)"
echo "  - Contents/MacOS/Models/AI/archibald-basev2.1.gguf  (the model, ~2.2 GB)"
echo "  - Contents/MacOS/NOTICE.txt  (the Llama 3.2 license text)"
echo ""
echo "Zip up $APP_BUNDLE as a whole to share it. Two things anyone you send it"
echo "to should know:"
echo "  1. It isn't Apple-notarized, so Gatekeeper will likely warn that it's"
echo "     from an unidentified developer the first time it's opened. The fix"
echo "     is the same as any other unsigned Mac app: right-click the .app,"
echo "     choose Open, and confirm - or System Settings > Privacy & Security"
echo "     > \"Open Anyway\" if that's what shows up instead."
echo "  2. The xattr step above only clears the quarantine flag on THIS Mac."
echo "     Once this .app is zipped and downloaded again on someone else's"
echo "     Mac, macOS re-applies its own quarantine flag to that fresh"
echo "     download - that's step 1 above, and no packaging step can get"
echo "     around it without real Apple code signing and notarization (a"
echo "     paid Apple Developer account), which this project doesn't have"
echo "     set up yet."
