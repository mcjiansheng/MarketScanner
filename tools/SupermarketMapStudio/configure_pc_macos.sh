#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPOSITORY="${SCRIPT_DIR:h:h}"
BUILD_DIR="${REPOSITORY}/build/marketscanner-macos-release"
BREW="/opt/homebrew/bin/brew"

if [[ ! -x "${BREW}" ]]; then
  BREW="$(command -v brew || true)"
fi
if [[ -z "${BREW}" || ! -x "${BREW}" ]]; then
  print -u2 "Homebrew was not found. Install it first, then rerun this script."
  exit 1
fi

FORMULAE=(cmake ninja pkg-config opencv@4 pcl g2o libomp)
MISSING=()
for formula in "${FORMULAE[@]}"; do
  if ! "${BREW}" list --versions "${formula}" >/dev/null 2>&1; then
    MISSING+=("${formula}")
  fi
done
if (( ${#MISSING[@]} )); then
  HOMEBREW_NO_AUTO_UPDATE=1 "${BREW}" install "${MISSING[@]}"
fi

BREW_PREFIX="$(${BREW} --prefix)"
LIBOMP_PREFIX="$(${BREW} --prefix libomp)"
OPENMP_FLAGS="-Xpreprocessor -fopenmp -I${LIBOMP_PREFIX}/include"

cd "${REPOSITORY}"
cmake --fresh --preset marketscanner-macos-release \
  -DOpenCV_DIR="${BREW_PREFIX}/opt/opencv@4/lib/cmake/opencv4" \
  -DEigen3_DIR="${BREW_PREFIX}/opt/eigen/share/eigen3/cmake" \
  -DEIGEN3_INCLUDE_DIR="${BREW_PREFIX}/include/eigen3" \
  -DOpenMP_C_FLAGS="${OPENMP_FLAGS}" \
  -DOpenMP_CXX_FLAGS="${OPENMP_FLAGS}" \
  -DOpenMP_C_LIB_NAMES=omp \
  -DOpenMP_CXX_LIB_NAMES=omp \
  -DOpenMP_omp_LIBRARY="${LIBOMP_PREFIX}/lib/libomp.dylib" \
  -DWITH_POINTMATCHER=OFF \
  -DWITH_FLYCAPTURE2=OFF \
  -DWITH_ZED=OFF \
  -DWITH_ZEDOC=OFF \
  -DWITH_REALSENSE=OFF \
  -DWITH_REALSENSE2=OFF \
  -DWITH_MYNTEYE=OFF \
  -DWITH_OCTOMAP=OFF \
  -DWITH_FASTCV=OFF \
  -DWITH_OPENGV=OFF \
  -DWITH_OPENMP=ON \
  -DWITH_VERTIGO=ON

JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || print 4)"
cmake --build --preset marketscanner-macos-release -j "${JOBS}"

BINARY="${BUILD_DIR}/bin/rtabmap-reprocess"
if [[ ! -x "${BINARY}" ]]; then
  print -u2 "Build completed without producing ${BINARY}."
  exit 1
fi

print "PC reprocessing environment is ready:"
print "  ${BINARY}"
print "  ${BUILD_DIR}/bin/rtabmap-prior-map-factor-graph"
print "  Release/O3 + OpenMP (${JOBS} build jobs)"
print "Supermarket Map Studio will discover this path automatically."
