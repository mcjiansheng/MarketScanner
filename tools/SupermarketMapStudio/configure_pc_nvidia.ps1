param(
    [string]$OpenCVDir = $env:OpenCV_DIR,
    [string]$BuildDir = "",
    [int]$Jobs = 0
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repository = (Resolve-Path (Join-Path $ScriptDir "../..")).Path
if (-not $BuildDir) { $BuildDir = Join-Path $Repository "build-pc-cuda" }
if (-not $OpenCVDir) { throw "Set -OpenCVDir to an OpenCV 4 CUDA build containing cudafeatures2d and cudaimgproc." }
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) { throw "CMake was not found." }
if (-not (Get-Command nvcc -ErrorAction SilentlyContinue)) { throw "NVIDIA CUDA Toolkit (nvcc) was not found." }
if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount }

cmake -S $Repository -B $BuildDir -G Ninja `
    -DCMAKE_BUILD_TYPE=Release `
    "-DOpenCV_DIR=$OpenCVDir" `
    -DBUILD_APP=OFF -DBUILD_TOOLS=ON -DBUILD_EXAMPLES=OFF `
    -DWITH_QT=OFF -DWITH_G2O=ON -DWITH_GTSAM=OFF -DWITH_CERES=OFF `
    -DWITH_OPENMP=ON -DWITH_VERTIGO=ON

$OpenCVFiles = Get-ChildItem -Path $OpenCVDir -Recurse -File
$CudaFeatures = $OpenCVFiles | Select-String "opencv_cudafeatures2d" | Select-Object -First 1
$CudaImageProc = $OpenCVFiles | Select-String "opencv_cudaimgproc" | Select-Object -First 1
if (-not $CudaFeatures -or -not $CudaImageProc) {
    throw "Configured OpenCV does not expose cudafeatures2d and cudaimgproc; CUDA build rejected."
}

cmake --build $BuildDir --target reprocess -j $Jobs
$BinDir = Join-Path $BuildDir "bin"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
$CudaSource = Join-Path $ScriptDir "native/gpu_depth_projector_cuda.cu"
$Projector = Join-Path $BinDir "supermarket-cuda-projector.exe"
nvcc -std=c++17 -O3 $CudaSource -o $Projector
& $Projector --probe
Write-Host "NVIDIA CUDA processing environment is ready: $BinDir"
