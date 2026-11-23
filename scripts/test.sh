#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build/tests"

MODE="default"
case "${1:-}" in
  "" ) MODE="default" ;;
  --coverage ) MODE="coverage" ;;
  --asan ) MODE="asan" ;;
  --tsan ) MODE="tsan" ;;
  --all ) MODE="all" ;;
  -h|--help )
    echo "Usage: ./scripts/test.sh [--coverage | --asan | --tsan | --all]"
    exit 0
    ;;
  * )
    echo "Unknown option: $1" >&2
    echo "Usage: ./scripts/test.sh [--coverage | --asan | --tsan | --all]" >&2
    exit 1
    ;;
esac

find_tool() {
  local name="$1"
  local found=""
  if command -v xcrun >/dev/null 2>&1; then
    found="$(xcrun --find "$name" 2>/dev/null || true)"
  fi
  if [[ -z "$found" || ! -x "$found" ]]; then
    if [[ -x "/Library/Developer/CommandLineTools/usr/bin/$name" ]]; then
      found="/Library/Developer/CommandLineTools/usr/bin/$name"
    else
      found="$(command -v "$name" 2>/dev/null || true)"
    fi
  fi
  echo "$found"
}

CLANG="$(find_tool clang)"
if [[ -z "$CLANG" || ! -x "$CLANG" ]]; then
  echo "Error: clang not found. Install Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
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
  echo "Error: macOS SDK not found." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"

compile_and_run() {
  local label="$1"
  local bin="$2"
  shift 2
  local extra_flags=("$@")

  echo "==> Building tests ($label)..."
  "$CLANG" \
    -fobjc-arc \
    -O0 \
    -g \
    -Wall \
    -Wextra \
    -Wno-unused-parameter \
    -Wno-unused-function \
    -isysroot "$SDK" \
    -mmacosx-version-min=12.0 \
    "${extra_flags[@]}" \
    -framework Cocoa \
    -framework AVFoundation \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework QuartzCore \
    -framework ApplicationServices \
    "$ROOT/tests/VoicePTTTests.m" \
    -o "$bin"

  echo "==> Running tests ($label)..."
  "$bin"
}

run_coverage() {
  local profraw="$BUILD_DIR/coverage.profraw"
  local profdata="$BUILD_DIR/coverage.profdata"
  local html_dir="$BUILD_DIR/coverage-html"
  local bin="$BUILD_DIR/voiceptt-tests-cov"

  local LLVM_PROFDATA="$(find_tool llvm-profdata)"
  local LLVM_COV="$(find_tool llvm-cov)"
  if [[ -z "$LLVM_PROFDATA" || -z "$LLVM_COV" ]]; then
    echo "Error: llvm-profdata / llvm-cov not found." >&2
    exit 1
  fi

  rm -rf "$profraw" "$profdata" "$html_dir"
  echo "==> Building tests (coverage)..."
  "$CLANG" \
    -fobjc-arc \
    -O0 \
    -g \
    -Wall \
    -Wextra \
    -Wno-unused-parameter \
    -Wno-unused-function \
    -fprofile-instr-generate \
    -fcoverage-mapping \
    -isysroot "$SDK" \
    -mmacosx-version-min=12.0 \
    -framework Cocoa \
    -framework AVFoundation \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework QuartzCore \
    -framework ApplicationServices \
    "$ROOT/tests/VoicePTTTests.m" \
    -o "$bin"

  echo "==> Running tests (coverage)..."
  LLVM_PROFILE_FILE="$profraw" "$bin"

  "$LLVM_PROFDATA" merge -sparse "$profraw" -o "$profdata"

  echo ""
  echo "==> Source-Based Coverage Report (src/VoicePTT.m):"
  "$LLVM_COV" report "$bin" -instr-profile="$profdata" "$ROOT/src/VoicePTT.m"

  "$LLVM_COV" show "$bin" \
    -instr-profile="$profdata" \
    -format=html \
    -output-dir="$html_dir" \
    "$ROOT/src/VoicePTT.m"

  echo ""
  echo "HTML coverage report written to: $html_dir/index.html"
}

case "$MODE" in
  default)
    compile_and_run "standard" "$BUILD_DIR/voiceptt-tests"
    ;;
  coverage)
    run_coverage
    ;;
  asan)
    compile_and_run "ASan + UBSan" "$BUILD_DIR/voiceptt-tests-asan" -fsanitize=address,undefined -fno-omit-frame-pointer
    ;;
  tsan)
    compile_and_run "TSan" "$BUILD_DIR/voiceptt-tests-tsan" -fsanitize=thread -fno-omit-frame-pointer
    ;;
  all)
    run_coverage
    echo ""
    compile_and_run "ASan + UBSan" "$BUILD_DIR/voiceptt-tests-asan" -fsanitize=address,undefined -fno-omit-frame-pointer
    echo ""
    compile_and_run "TSan" "$BUILD_DIR/voiceptt-tests-tsan" -fsanitize=thread -fno-omit-frame-pointer
    ;;
esac
