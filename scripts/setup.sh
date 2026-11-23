#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="${1:-large-v3-turbo-q5_0}"
VAD_MODEL="silero-v6.2.0"

echo "==> 1/3 Ensuring whisper.cpp submodule is checked out..."
if [[ ! -f "$ROOT/whisper.cpp/CMakeLists.txt" ]]; then
  git -C "$ROOT" submodule update --init --recursive
fi

echo "==> 2/3 Building static whisper-server..."
ARCH="$(uname -m)"
CMAKE_ARGS=(
  -B "$ROOT/whisper.cpp/build"
  -S "$ROOT/whisper.cpp"
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=OFF
  -DWHISPER_BUILD_SERVER=ON
  -DWHISPER_BUILD_TESTS=OFF
  -DGGML_ACCELERATE=ON
)

if [[ "$ARCH" == "arm64" ]]; then
  CMAKE_ARGS+=(-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
else
  CMAKE_ARGS+=(-DGGML_METAL=OFF)
fi

cmake "${CMAKE_ARGS[@]}"
cmake --build "$ROOT/whisper.cpp/build" --target whisper-server -j "$(sysctl -n hw.ncpu)"

echo "==> 3/3 Downloading Whisper ($MODEL) and Silero VAD ($VAD_MODEL) models..."
mkdir -p "$ROOT/models"
sh "$ROOT/whisper.cpp/models/download-ggml-model.sh" "$MODEL" "$ROOT/models"
sh "$ROOT/whisper.cpp/models/download-vad-model.sh" "$VAD_MODEL" "$ROOT/models"

echo ""
echo "Setup complete! Now run:"
echo "  ./build.sh"
echo "  open VoicePTT.app"
