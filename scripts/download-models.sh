#!/bin/zsh
set -euo pipefail

# Standalone model downloader for prebuilt VoicePTT releases (no git/cmake required).
# Usage:
#   ./download-models.sh                      # installs large-v3-turbo-q5_0 + Silero VAD
#   ./download-models.sh small.en-q5_1        # installs small.en-q5_1 + Silero VAD
#   ./download-models.sh large-v3-turbo-q5_0 ./models

MODEL="${1:-large-v3-turbo-q5_0}"
DEST="${2:-$HOME/Library/Application Support/VoicePTT/models}"
VAD_FILE="ggml-silero-v6.2.0.bin"
MODEL_FILE="ggml-${MODEL}.bin"

mkdir -p "$DEST"

download_if_missing() {
  local url="$1"
  local out="$2"
  if [[ -f "$out" ]]; then
    echo "Already exists: $out"
    return 0
  fi
  echo "Downloading $(basename "$out")..."
  curl -fL --progress-bar "$url" -o "${out}.tmp"
  mv "${out}.tmp" "$out"
}

download_if_missing \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_FILE}" \
  "$DEST/${MODEL_FILE}"

download_if_missing \
  "https://huggingface.co/ggml-org/whisper-vad/resolve/main/${VAD_FILE}" \
  "$DEST/${VAD_FILE}"

echo ""
echo "Models installed to: $DEST"
echo "Launch VoicePTT.app (or click 'Restart Whisper Engine' if already running)."
