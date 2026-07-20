#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${REPOSITORY}/build-pc-cuda"
CUDA_SOURCE="${SCRIPT_DIR}/native/gpu_depth_projector_cuda.cu"
OPEN_CV_DIR="${OpenCV_DIR:-${OPENCV_DIR:-}}"

if ! command -v cmake >/dev/null 2>&1 || ! command -v nvcc >/dev/null 2>&1; then
  echo "CMake and the NVIDIA CUDA Toolkit (nvcc) are required." >&2
  exit 1
fi
if [[ -z "${OPEN_CV_DIR}" ]]; then
  echo "Set OpenCV_DIR to an OpenCV 4 build containing cudafeatures2d and cudaimgproc." >&2
  exit 1
fi

cmake -S "${REPOSITORY}" -B "${BUILD_DIR}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DOpenCV_DIR="${OPEN_CV_DIR}" \
  -DBUILD_APP=OFF \
  -DBUILD_TOOLS=ON \
  -DBUILD_EXAMPLES=OFF \
  -DWITH_QT=OFF \
  -DWITH_G2O=ON \
  -DWITH_GTSAM=OFF \
  -DWITH_CERES=OFF \
  -DWITH_OPENMP=ON \
  -DWITH_VERTIGO=ON \
  -DWITH_CUDASIFT="${WITH_CUDASIFT:-OFF}"

if ! grep -Rqs "opencv_cudafeatures2d" "${OPEN_CV_DIR}" ||
   ! grep -Rqs "opencv_cudaimgproc" "${OPEN_CV_DIR}"; then
  echo "Configured OpenCV does not expose cudafeatures2d and cudaimgproc; refusing to label this build CUDA accelerated." >&2
  exit 1
fi

cmake --build "${BUILD_DIR}" --target reprocess -j "${JOBS:-$(nproc)}"
mkdir -p "${BUILD_DIR}/bin"
nvcc -std=c++17 -O3 "${CUDA_SOURCE}" -o "${BUILD_DIR}/bin/supermarket-cuda-projector"
"${BUILD_DIR}/bin/supermarket-cuda-projector" --probe

echo "NVIDIA CUDA processing environment is ready:"
echo "  ${BUILD_DIR}/bin/rtabmap-reprocess"
echo "  ${BUILD_DIR}/bin/supermarket-cuda-projector"
