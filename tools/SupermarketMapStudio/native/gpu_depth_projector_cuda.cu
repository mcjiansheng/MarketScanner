#include <cuda_runtime.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kProtocolVersion = 1;

#pragma pack(push, 1)
struct RequestHeader {
    char magic[4];
    uint32_t version;
    uint32_t width;
    uint32_t height;
    uint32_t step;
    uint32_t axes;
    uint32_t depthCount;
    float maxDepth;
    float fx;
    float fy;
    float cx;
    float cy;
    float correctionDx;
    float correctionDy;
    float correctionYaw;
    float localTransform[12];
    float rawTransform[12];
};

struct ReplyHeader {
    char magic[4];
    uint32_t version;
    uint32_t gridWidth;
    uint32_t gridHeight;
    uint32_t pointCount;
};
#pragma pack(pop)

static_assert(sizeof(RequestHeader) == 156, "GPU projection protocol header changed");
static_assert(sizeof(ReplyHeader) == 20, "GPU projection reply header changed");

struct ProjectionParams {
    uint32_t width;
    uint32_t height;
    uint32_t step;
    uint32_t axes;
    uint32_t gridWidth;
    float maxDepth;
    float fx;
    float fy;
    float cx;
    float cy;
    float correctionDx;
    float correctionDy;
    float correctionYaw;
    float localTransform[12];
    float rawTransform[12];
};

__device__ float3 transformPoint(const float *m, float3 p) {
    return make_float3(
        m[0] * p.x + m[1] * p.y + m[2] * p.z + m[3],
        m[4] * p.x + m[5] * p.y + m[6] * p.z + m[7],
        m[8] * p.x + m[9] * p.y + m[10] * p.z + m[11]);
}

__global__ void projectDepth(const float *depths, float4 *output, ProjectionParams p, uint32_t count) {
    uint32_t gid = blockIdx.x * blockDim.x + threadIdx.x;
    if (gid >= count) return;
    uint32_t gridRow = gid / p.gridWidth;
    uint32_t gridColumn = gid - gridRow * p.gridWidth;
    uint32_t row = gridRow * p.step;
    uint32_t column = gridColumn * p.step;
    float depth = depths[row * p.width + column];
    if (!isfinite(depth) || depth <= 0.05f || depth > p.maxDepth) {
        output[gid] = make_float4(NAN, NAN, NAN, NAN);
        return;
    }
    float3 cameraPoint = make_float3(
        (float(column) - p.cx) * depth / p.fx,
        (float(row) - p.cy) * depth / p.fy,
        depth);
    float3 localPoint = transformPoint(p.localTransform, cameraPoint);
    float3 nativeWorld = transformPoint(p.rawTransform, localPoint);
    float pointX = p.axes == 0 ? -nativeWorld.y : nativeWorld.x;
    float pointY = p.axes == 0 ? -nativeWorld.x : nativeWorld.y;
    float pointHeight = nativeWorld.z;
    float c = cosf(p.correctionYaw);
    float s = sinf(p.correctionYaw);
    output[gid] = make_float4(
        c * pointX - s * pointY + p.correctionDx,
        s * pointX + c * pointY + p.correctionDy,
        pointHeight,
        depth);
}

bool cudaOk(cudaError_t status, const char *operation) {
    if (status == cudaSuccess) return true;
    std::fprintf(stderr, "%s failed: %s\n", operation, cudaGetErrorString(status));
    return false;
}

int probe() {
    int count = 0;
    if (!cudaOk(cudaGetDeviceCount(&count), "cudaGetDeviceCount") || count <= 0) return 2;
    cudaDeviceProp properties{};
    if (!cudaOk(cudaGetDeviceProperties(&properties, 0), "cudaGetDeviceProperties")) return 3;
    std::printf(
        "{\"available\":true,\"backend\":\"nvidia_cuda\",\"device\":\"%s\","
        "\"device_count\":%d,\"compute_capability\":\"%d.%d\",\"protocol\":%u}\n",
        properties.name, count, properties.major, properties.minor, kProtocolVersion);
    return 0;
}

int runServer() {
    int count = 0;
    if (!cudaOk(cudaGetDeviceCount(&count), "cudaGetDeviceCount") || count <= 0) return 2;
    float *deviceDepths = nullptr;
    float4 *deviceOutput = nullptr;
    size_t depthCapacity = 0;
    size_t outputCapacity = 0;
    while (true) {
        RequestHeader request{};
        size_t headerRead = std::fread(&request, 1, sizeof(request), stdin);
        if (headerRead == 0 && std::feof(stdin)) break;
        if (headerRead != sizeof(request) || std::memcmp(request.magic, "SMGP", 4) != 0 ||
            request.version != kProtocolVersion || request.width == 0 || request.height == 0 ||
            request.step == 0 || request.depthCount != request.width * request.height) {
            std::fprintf(stderr, "Invalid CUDA projection request\n");
            return 4;
        }
        std::vector<float> depths(request.depthCount);
        if (std::fread(depths.data(), sizeof(float), depths.size(), stdin) != depths.size()) return 5;
        uint32_t gridWidth = (request.width + request.step - 1) / request.step;
        uint32_t gridHeight = (request.height + request.step - 1) / request.step;
        uint32_t pointCount = gridWidth * gridHeight;
        size_t depthBytes = depths.size() * sizeof(float);
        size_t outputBytes = pointCount * sizeof(float4);
        if (depthBytes > depthCapacity) {
            cudaFree(deviceDepths);
            if (!cudaOk(cudaMalloc(reinterpret_cast<void **>(&deviceDepths), depthBytes), "cudaMalloc depths")) return 6;
            depthCapacity = depthBytes;
        }
        if (outputBytes > outputCapacity) {
            cudaFree(deviceOutput);
            if (!cudaOk(cudaMalloc(reinterpret_cast<void **>(&deviceOutput), outputBytes), "cudaMalloc output")) return 7;
            outputCapacity = outputBytes;
        }
        if (!cudaOk(cudaMemcpy(deviceDepths, depths.data(), depthBytes, cudaMemcpyHostToDevice), "depth upload")) return 8;
        ProjectionParams params{};
        params.width = request.width;
        params.height = request.height;
        params.step = request.step;
        params.axes = request.axes;
        params.gridWidth = gridWidth;
        params.maxDepth = request.maxDepth;
        params.fx = request.fx;
        params.fy = request.fy;
        params.cx = request.cx;
        params.cy = request.cy;
        params.correctionDx = request.correctionDx;
        params.correctionDy = request.correctionDy;
        params.correctionYaw = request.correctionYaw;
        std::memcpy(params.localTransform, request.localTransform, sizeof(params.localTransform));
        std::memcpy(params.rawTransform, request.rawTransform, sizeof(params.rawTransform));
        constexpr uint32_t blockSize = 256;
        projectDepth<<<(pointCount + blockSize - 1) / blockSize, blockSize>>>(deviceDepths, deviceOutput, params, pointCount);
        if (!cudaOk(cudaGetLastError(), "projectDepth launch")) return 9;
        std::vector<float4> output(pointCount);
        if (!cudaOk(cudaMemcpy(output.data(), deviceOutput, outputBytes, cudaMemcpyDeviceToHost), "projection download")) return 10;
        ReplyHeader reply{{'S', 'M', 'G', 'O'}, kProtocolVersion, gridWidth, gridHeight, pointCount};
        if (std::fwrite(&reply, 1, sizeof(reply), stdout) != sizeof(reply) ||
            std::fwrite(output.data(), 1, outputBytes, stdout) != outputBytes) return 11;
        std::fflush(stdout);
    }
    cudaFree(deviceDepths);
    cudaFree(deviceOutput);
    return 0;
}

}  // namespace

int main(int argc, char **argv) {
    if (argc == 2 && std::strcmp(argv[1], "--probe") == 0) return probe();
    if (argc == 2 && std::strcmp(argv[1], "--server") == 0) return runServer();
    std::fprintf(stderr, "Usage: %s --probe|--server\n", argv[0]);
    return 1;
}
