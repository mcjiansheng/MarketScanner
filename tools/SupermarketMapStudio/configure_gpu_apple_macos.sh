#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPOSITORY="${SCRIPT_DIR:h:h}"
SOURCE="${SCRIPT_DIR}/native/gpu_depth_projector_metal.mm"
OUTPUT_DIR="${REPOSITORY}/build-pc-release/bin"
OUTPUT="${OUTPUT_DIR}/supermarket-metal-projector"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  print -u2 "Apple Metal acceleration requires an Apple Silicon Mac."
  exit 1
fi
if ! xcrun --find clang++ >/dev/null 2>&1; then
  print -u2 "Xcode command line tools were not found. Run: xcode-select --install"
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
xcrun clang++ -std=c++17 -O3 -DNDEBUG -fobjc-arc \
  -framework Foundation -framework Metal \
  "${SOURCE}" -o "${OUTPUT}"

"${OUTPUT}" --probe
print "Apple Metal depth projection backend is ready:"
print "  ${OUTPUT}"
