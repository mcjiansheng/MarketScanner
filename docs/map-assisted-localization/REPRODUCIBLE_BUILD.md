# MarketScanner 可复现构建与依赖供应链

> 文档状态：**当前有效**。最后核对日期：2026-07-28。

## PC release preset

所有发布构建从空目录使用仓库根部 `CMakePresets.json`：

```bash
cmake --fresh --preset marketscanner-linux-release
cmake --build --preset marketscanner-linux-release -j2
```

macOS 使用 `tools/SupermarketMapStudio/configure_pc_macos.sh` 安装/发现 Homebrew 依赖后调用同一 preset；Windows 使用 `marketscanner-windows-release` 并由操作者提供已锁定的依赖前缀。release preset 强制 g2o、Eigen 和 OpenCV capability 检查，构建 `rtabmap-reprocess` 与 `rtabmap-prior-map-factor-graph`。OpenCV 4 是当前 CI/本机验证矩阵；OpenCV 5 允许进入 capability configure，但在专门 clean CI 实际编译通过前仍视为候选兼容，不可仅凭 major check 宣称已认证。

两个 native 工具支持 `--version`，输出 RTAB-Map 版本和 configure 时绑定的 40 位 Git SHA。`MARKETSCANNER_RELEASE_BUILD=ON` 时无法得到准确 SHA、g2o 或 Eigen 会直接 configure 失败。

## Release manifest

`tools/SupermarketMapStudio/release_manifest.py` 为实际二进制生成 `MarketScannerReleaseManifest` version 1，记录平台、UTC 构建时间、Git SHA、工具链、依赖 policy SHA、许可证提示以及每个产物的字节数/SHA-256。固定输入和时间产生相同 canonical body hash。发布或 field acceptance 必须引用 manifest SHA，不能只写“最新版”。

依赖能力和许可证入口为 `tools/SupermarketMapStudio/release_dependencies.json`。它是 policy，不伪装成某台机器的 resolved lock；实际版本和产物身份由 configure summary、binary `--version` 和 release manifest 共同绑定。

## iOS native dependency cache

hosted macOS CI 的 cache key 同时绑定 runner architecture、`install_deps.sh` 和 dependency policy。cache miss 必须实际运行 native dependency build；不再把依赖缺失记为成功 skip。`ios_dependency_manifest.py` 对生成的全部 `Libraries/include` 与 `Libraries/lib` regular files记录 bytes/SHA-256，并记录仍保留在 build tree 中的第三方 Git HEAD/patch 状态。cache restore 后先逐文件验证该 manifest，再执行 unsigned generic arm64 app compile/link。

首次 hosted cold-cache run `30361769032` 验证了 Ubuntu clean native build，但在 iOS GTSAM 编译时暴露 Boost 1.88 需要 C++14 以后标准库别名、而生成工程仍使用旧标准的问题。依赖脚本现对 GTSAM 同时固定 `CMAKE_CXX_STANDARD=17` 与 `GTSAM_CXX_STANDARD=17`，要求标准且关闭 compiler extensions；该失败 run 是修复依据，不能记作成功证据，后续 run 必须重新完成 dependency manifest 和 App 全量链接。

第二次 cold-cache run `30362995994` 已通过 GTSAM 并继续验证 Ubuntu clean native build，但在 g2o `string_tools.cpp` 暴露 iOS target macros 未进入 translation unit，导致错误选择 `wordexp/wordfree` 分支。g2o iOS configure 现强制预包含 Apple SDK 的 `TargetConditionals.h`，让 upstream 条件编译使用 SDK 定义；该 run 仍是失败证据，完整 iOS dependency manifest/App link 必须由下一次 run 证明。

该流程提供可追溯 build/cache 合同；首次 hosted 构建是否能在 runner 时间和上游可用性范围内完成，必须以 GitHub Actions 结果为准。任何 cache/build/link 失败都保持 P2 阻断，不能降级为 skipped success。

## 已执行证据

2026-07-28 在新的 `build/marketscanner-macos-release` 目录执行 `cmake --fresh`，从 0 编译 151 个步骤，成功链接两个工具；OpenCV 4.14.0、PCL 1.15.1、g2o 1.0.0、CMake 4.4.0，二进制均报告基线 SHA `c999d6cce2711bdade3ef8ee079cbad8ebfd9c1e`。本机 clean build 不替代 Ubuntu hosted clean job、Windows clean build或 hosted iOS cold-cache link。
