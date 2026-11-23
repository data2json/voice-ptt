#!/bin/zsh
set -euo pipefail

ROOT="/Users/essobi/Downloads/voice-ptt"
APP="$ROOT/VoicePTT.app"
CLANG="/Library/Developer/CommandLineTools/usr/bin/clang"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX12.3.sdk"

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
cp "$ROOT/whisper.cpp/build/bin/whisper-server" "$APP/Contents/Resources/whisper-server"
chmod +x "$APP/Contents/MacOS/VoicePTT" "$APP/Contents/Resources/whisper-server"

codesign --force --deep --sign - "$APP"
echo "Built $APP successfully."
