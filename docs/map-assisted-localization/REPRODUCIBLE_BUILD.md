# MarketScanner 可复现构建与依赖供应链

> 文档状态：**当前有效**。最后核对日期：2026-07-30。

## PC release preset

所有发布构建从空目录使用仓库根部 `CMakePresets.json`：

```bash
cmake --fresh --preset marketscanner-linux-release
cmake --build --preset marketscanner-linux-release -j2
```

macOS 使用 `tools/SupermarketMapStudio/configure_pc_macos.sh` 安装/发现 Homebrew 依赖后调用同一 preset；Windows 使用 `marketscanner-windows-release` 和 SHA-256 固定的 RTAB-Map 官方 vcpkg export。hosted Windows Job 从 fresh build tree 生成两个 `.exe` 并校验 source SHA、manifest 和 artifact。release preset 强制 g2o、Eigen 和 OpenCV capability 检查，构建 `rtabmap-reprocess` 与 `rtabmap-prior-map-factor-graph`。OpenCV 4 是当前 CI/本机验证矩阵；OpenCV 5 允许进入 capability configure，但在专门 clean CI 实际编译通过前仍视为候选兼容，不可仅凭 major check 宣称已认证。

两个 native 工具支持 `--version`，输出 RTAB-Map 版本和 configure 时绑定的 40 位 Git SHA。`MARKETSCANNER_RELEASE_BUILD=ON` 时无法得到准确 SHA、g2o 或 Eigen 会直接 configure 失败。

## Release manifest

`tools/SupermarketMapStudio/release_manifest.py` 为实际二进制生成 `MarketScannerReleaseManifest` version 2，记录产品版本、平台、UTC 构建时间、Git SHA、工具链、依赖 policy SHA、因子图质量 policy SHA/状态以及每个产物的字节数/SHA-256。固定输入和时间产生相同 canonical body hash。发布或 field acceptance 必须引用 manifest SHA，不能只写“最新版”。

依赖能力和许可证入口为 `tools/SupermarketMapStudio/release_dependencies.json`。它是 policy，不伪装成某台机器的 resolved lock；实际版本和产物身份由 configure summary、binary `--version` 和 release manifest 共同绑定。

## iOS native dependency cache

hosted macOS CI 的 cache key 同时绑定 runner architecture、`install_deps.sh` 和 dependency policy。cache miss 必须实际运行 native dependency build；不再把依赖缺失记为成功 skip。`ios_dependency_manifest.py` 对生成的全部 `Libraries/include` 与 `Libraries/lib` regular files记录 bytes/SHA-256，并记录仍保留在 build tree 中的第三方 Git HEAD/patch 状态。无论 fresh build 或 restore，都先逐文件验证 manifest；cache miss 在验证成功后、App link 前立即保存已验证 cache，避免后续 App 错误丢失完整依赖成果；随后执行 unsigned generic arm64 App compile/link。

首次 hosted cold-cache run `30361769032` 验证了 Ubuntu clean native build，但在 iOS GTSAM 编译时暴露 Boost 1.88 需要 C++14 以后标准库别名、而生成工程仍使用旧标准的问题。依赖脚本现对 GTSAM 同时固定 `CMAKE_CXX_STANDARD=17` 与 `GTSAM_CXX_STANDARD=17`，要求标准且关闭 compiler extensions；该失败 run 是修复依据，不能记作成功证据，后续 run 必须重新完成 dependency manifest 和 App 全量链接。

第二次 cold-cache run `30362995994` 已通过 GTSAM 并继续验证 Ubuntu clean native build，但在 g2o `string_tools.cpp` 暴露 iOS target macros 未进入 translation unit，导致错误选择 `wordexp/wordfree` 分支。g2o iOS configure 现强制预包含 Apple SDK 的 `TargetConditionals.h`，让 upstream 条件编译使用 SDK 定义；该 run 仍是失败证据，完整 iOS dependency manifest/App link 必须由下一次 run 证明。

第三次 P2 cold-cache run `30364782777` 与累计分支 run `30369695922` 均继续通过 GTSAM、g2o 和 LASzip，随后在 libLAS 1.8.1 的旧 CMake policy 处被 CMake 4 拒绝。第一次修复提交 `277793c8d5e82610062e56c0723eccd93dfd9c50` 只加入 policy floor；对精确 `1.8.1` 源码复核后确认原脚本的 minimum-version `sed` 不匹配该标签，且该标签无条件要求 GeoTIFF，因而 `WITH_GEOTIFF=OFF` 实际无效。该提交不能作为完整修复或 full-link 证据。

累计代码提交 `089d0894d8d90a7a30cf476967088b1a67fa4c96` 将 libLAS 固定到精确提交 `33097f17e27b853ac7b9651025a70354ffb10cfc`；该版本明确支持关闭非生产必需的 GeoTIFF，同时保留 iOS LAS/LAZ 导出所需的 libLAS/LASzip。2026-07-29 已在隔离目录以 Xcode 26.5、iPhoneOS 26.5 SDK、arm64/iOS 12 target 实际完成 configure，并成功生成 `liblas.a` 与 `liblas_c.a`；合同测试同时锁定 revision、policy floor 和 GeoTIFF-off 选项。该本机依赖级验证不替代 hosted dependency manifest 与完整 App link，P2 iOS 门在后续 Actions run 成功前继续保持未关闭。

累计分支 run `30455290658` 已再次完成 Ubuntu 空目录 native release build；其 Windows job 暴露取消测试 fixture 依赖 POSIX shebang，`089d089...` 已改为由当前 Python 解释器启动同一实际子进程，保留取消、日志和源库不变断言。该旧 run 随后被取消，以让累计 SHA 取得 runner。

累计 SHA run `30456477770` 的 P0、Native ABI、Ubuntu Python/API/Web、Windows 全套回归和 Ubuntu clean native release build 均成功；Windows fixture 修复已获得远端证明。iOS cold build 从空 cache 完成 VTK 后，在首次 clone PCL 时遇到 runner 的瞬时 DNS 失败（`Could not resolve host: github.com`），因此 dependency manifest 与 App link 正确保持 skipped，不能算 P2 通过。代码提交 `6be21b07c32cdb5f1dd4fe3f0cd7eae54e2ef8c8` 为全部 11 个第三方 Git clone 加入最多 3 次的有界重试，并在唯一临时目录中 clone 后才原子移动到正式依赖目录；所有 curl 下载同样使用有界 retry、fail-on-HTTP-error 和 `.partial` 临时文件。合同测试禁止以后绕过统一 fetch helper。该修复仍须由下一次 cold-cache run 完整验证，且 `30456477770` 没有到达 PCL 构建后的 libLAS/RTAB-Map/App link，不能用于证明这些阶段。

累计 SHA run `30462392903` 完成了全冷依赖构建与逐文件 manifest 验证，随后 App link 暴露 SuiteSparse/CHOLMOD 的 BLAS/LAPACK 符号（如 `dgemm_`、`dpotrf_`、`ztrsm_`）没有 provider。代码提交 `8b3d06e0807752f515ca9ab6704152891338abde` 在 Xcode target 显式链接系统 `Accelerate.framework`，为 VTK 外部 iOS build 固定 `IOS_DEPLOYMENT_TARGET=12.0`，并把已验证 dependency cache 的保存移到 App link 前。该修复在本机 Xcode 26.5 先完成 unsigned arm64 Release full link；失败 run 只作为真实缺陷发现证据。

最终 run [30470632088](https://github.com/mcjiansheng/MarketScanner/actions/runs/30470632088) 精确绑定 `8b3d06e0807752f515ca9ab6704152891338abde`，七个 Job 全部成功。Windows clean native Job `90639620341` 从 fresh tree 构建两个 `.exe`、验证 source-bound version、生成 release manifest 并上传 artifact；Ubuntu clean native Job `90639620411` 完成同等 Linux 合同；macOS/iOS Job `90639620443` 从 cold cache 生成全依赖、验证 dependency manifest、保存验证后 cache，并完成 unsigned generic arm64 App 全量编译与链接。该 run 关闭 P2 自动化 clean-build 出口，但不替代 P5 真机或 P7 干净终端安装/升级/卸载 smoke。

任何后续验证必须报告实际 checkout SHA；不得把前述失败 run、仅通过 Python 合同测试或依赖级静态库编译视为 hosted native full App link 证据。

该流程提供可追溯 build/cache 合同；首次 hosted 构建是否能在 runner 时间和上游可用性范围内完成，必须以 GitHub Actions 结果为准。任何 cache/build/link 失败都保持 P2 阻断，不能降级为 skipped success。

## 已执行证据

2026-07-28 在新的 `build/marketscanner-macos-release` 目录执行 `cmake --fresh`，从 0 编译 151 个步骤，成功链接两个工具；OpenCV 4.14.0、PCL 1.15.1、g2o 1.0.0、CMake 4.4.0，二进制均报告基线 SHA `c999d6cce2711bdade3ef8ee079cbad8ebfd9c1e`。该本机证据现由 run `30470632088` 的 Ubuntu、Windows 和 hosted iOS clean build 补充；它们仍不替代真机和干净运营终端安装验收。
