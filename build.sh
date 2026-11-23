#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/VoicePTT.app"
WHISPER_SERVER="$ROOT/whisper.cpp/build/bin/whisper-server"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [[ ! -x "$WHISPER_SERVER" ]]; then
  echo "Error: whisper-server binary not found at $WHISPER_SERVER" >&2
  echo "Run ./scripts/setup.sh first to build whisper.cpp and download models." >&2
  exit 1
fi

if [[ -x "/Library/Developer/CommandLineTools/usr/bin/clang" ]]; then
  CLANG="/Library/Developer/CommandLineTools/usr/bin/clang"
else
  CLANG="$(command -v clang)"
fi

SDK=""
if command -v xcrun >/dev/null 2>&1; then
  SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
fi
if [[ -z "$SDK" || ! -d "$SDK" ]]; then
  for cand in \
    /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX13.1.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX12.3.sdk; do
    if [[ -d "$cand" ]]; then
      SDK="$cand"
      break
    fi
  done
fi

if [[ -z "$SDK" || ! -d "$SDK" ]]; then
  echo "Error: macOS SDK not found. Install Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

"$CLANG" \
  -fobjc-arc \
  -O2 \
  -Wall \
  -isysroot "$SDK" \
  -mmacosx-version-min=12.0 \
  -framework Cocoa \
  -framework AVFoundation \
  -framework AudioToolbox \
  -framework CoreAudio \
  -framework QuartzCore \
  -framework ApplicationServices \
  "$ROOT/src/VoicePTT.m" \
  -o "$APP/Contents/MacOS/VoicePTT"

cp "$ROOT/src/Info.plist" "$APP/Contents/Info.plist"
cp "$WHISPER_SERVER" "$APP/Contents/Resources/whisper-server"
chmod +x "$APP/Contents/MacOS/VoicePTT" "$APP/Contents/Resources/whisper-server"

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP successfully."
