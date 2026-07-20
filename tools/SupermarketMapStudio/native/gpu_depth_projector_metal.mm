#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
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

NSString *shaderSource() {
    return [NSString stringWithUTF8String:R"METAL(
#include <metal_stdlib>
using namespace metal;

struct ProjectionParams {
    uint width;
    uint height;
    uint step;
    uint axes;
    uint gridWidth;
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

float3 transformPoint(constant float *m, float3 p) {
    return float3(
        m[0] * p.x + m[1] * p.y + m[2] * p.z + m[3],
        m[4] * p.x + m[5] * p.y + m[6] * p.z + m[7],
        m[8] * p.x + m[9] * p.y + m[10] * p.z + m[11]);
}

kernel void projectDepth(
    device const float *depths [[buffer(0)]],
    device float4 *output [[buffer(1)]],
    constant ProjectionParams &p [[buffer(2)]],
    uint gid [[thread_position_in_grid]]) {
    uint gridHeight = (p.height + p.step - 1) / p.step;
    uint count = p.gridWidth * gridHeight;
    if (gid >= count) return;
    uint gridRow = gid / p.gridWidth;
    uint gridColumn = gid - gridRow * p.gridWidth;
    uint row = gridRow * p.step;
    uint column = gridColumn * p.step;
    float depth = depths[row * p.width + column];
    if (!isfinite(depth) || depth <= 0.05f || depth > p.maxDepth) {
        output[gid] = float4(NAN);
        return;
    }
    float3 cameraPoint = float3(
        (float(column) - p.cx) * depth / p.fx,
        (float(row) - p.cy) * depth / p.fy,
        depth);
    float3 localPoint = transformPoint(p.localTransform, cameraPoint);
    float3 nativeWorld = transformPoint(p.rawTransform, localPoint);
    float pointX;
    float pointY;
    float pointHeight;
    if (p.axes == 0) {
        pointX = -nativeWorld.y;
        pointY = -nativeWorld.x;
        pointHeight = nativeWorld.z;
    } else {
        pointX = nativeWorld.x;
        pointY = nativeWorld.y;
        pointHeight = nativeWorld.z;
    }
    float c = cos(p.correctionYaw);
    float s = sin(p.correctionYaw);
    float correctedX = c * pointX - s * pointY + p.correctionDx;
    float correctedY = s * pointX + c * pointY + p.correctionDy;
    output[gid] = float4(correctedX, correctedY, pointHeight, depth);
}
)METAL"];
}

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

bool writeAll(const void *data, size_t size) {
    return std::fwrite(data, 1, size, stdout) == size;
}

int runServer(id<MTLDevice> device) {
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:shaderSource() options:nil error:&error];
    if (!library) {
        std::fprintf(stderr, "Metal shader compilation failed: %s\n", error.localizedDescription.UTF8String);
        return 3;
    }
    id<MTLFunction> function = [library newFunctionWithName:@"projectDepth"];
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
    if (!pipeline) {
        std::fprintf(stderr, "Metal pipeline creation failed: %s\n", error.localizedDescription.UTF8String);
        return 4;
    }
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) {
        std::fprintf(stderr, "Metal command queue creation failed\n");
        return 5;
    }

    while (true) {
        RequestHeader request{};
        size_t headerRead = std::fread(&request, 1, sizeof(request), stdin);
        if (headerRead == 0 && std::feof(stdin)) break;
        if (headerRead != sizeof(request) || std::memcmp(request.magic, "SMGP", 4) != 0 ||
            request.version != kProtocolVersion || request.width == 0 || request.height == 0 ||
            request.step == 0 || request.depthCount != request.width * request.height) {
            std::fprintf(stderr, "Invalid Metal projection request\n");
            return 6;
        }
        std::vector<float> depths(request.depthCount);
        if (std::fread(depths.data(), sizeof(float), depths.size(), stdin) != depths.size()) {
            std::fprintf(stderr, "Truncated Metal projection depth payload\n");
            return 7;
        }

        uint32_t gridWidth = (request.width + request.step - 1) / request.step;
        uint32_t gridHeight = (request.height + request.step - 1) / request.step;
        uint32_t pointCount = gridWidth * gridHeight;
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

        id<MTLBuffer> depthBuffer = [device newBufferWithBytes:depths.data()
                                                        length:depths.size() * sizeof(float)
                                                       options:MTLResourceStorageModeShared];
        id<MTLBuffer> outputBuffer = [device newBufferWithLength:pointCount * sizeof(float) * 4
                                                        options:MTLResourceStorageModeShared];
        id<MTLBuffer> paramsBuffer = [device newBufferWithBytes:&params
                                                        length:sizeof(params)
                                                       options:MTLResourceStorageModeShared];
        if (!depthBuffer || !outputBuffer || !paramsBuffer) {
            std::fprintf(stderr, "Metal shared buffer allocation failed\n");
            return 8;
        }

        id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:depthBuffer offset:0 atIndex:0];
        [encoder setBuffer:outputBuffer offset:0 atIndex:1];
        [encoder setBuffer:paramsBuffer offset:0 atIndex:2];
        NSUInteger groupWidth = std::min<NSUInteger>(pipeline.maxTotalThreadsPerThreadgroup, 256);
        [encoder dispatchThreads:MTLSizeMake(pointCount, 1, 1)
          threadsPerThreadgroup:MTLSizeMake(groupWidth, 1, 1)];
        [encoder endEncoding];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        if (commandBuffer.status == MTLCommandBufferStatusError) {
            std::fprintf(stderr, "Metal command failed: %s\n", commandBuffer.error.localizedDescription.UTF8String);
            return 9;
        }

        ReplyHeader reply{{'S', 'M', 'G', 'O'}, kProtocolVersion, gridWidth, gridHeight, pointCount};
        if (!writeAll(&reply, sizeof(reply)) ||
            !writeAll(outputBuffer.contents, pointCount * sizeof(float) * 4)) {
            return 10;
        }
        std::fflush(stdout);
    }
    return 0;
}

}  // namespace

int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            std::fprintf(stderr, "No Metal device is available\n");
            return 2;
        }
        if (argc == 2 && std::strcmp(argv[1], "--probe") == 0) {
            NSDictionary *payload = @{
                @"available": @YES,
                @"backend": @"apple_metal",
                @"device": device.name ?: @"Apple GPU",
                @"protocol": @(kProtocolVersion),
                @"unified_memory": @(device.hasUnifiedMemory),
            };
            NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
            std::fwrite(json.bytes, 1, json.length, stdout);
            std::fputc('\n', stdout);
            return 0;
        }
        if (argc == 2 && std::strcmp(argv[1], "--server") == 0) {
            return runServer(device);
        }
        std::fprintf(stderr, "Usage: %s --probe|--server\n", argv[0]);
        return 1;
    }
}
