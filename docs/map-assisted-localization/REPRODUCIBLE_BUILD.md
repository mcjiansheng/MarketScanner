# MarketScanner 可复现构建与依赖供应链

> 文档状态：**当前有效**。最后核对日期：2026-08-17。

MapCase02 reproducibility golden：source SHA `1ddf428fc4dd6e4e8bd33258d0cbfaab87b809c4dedd6b8baca9e167c14b5e6a`，canonical ID `piaseczno-5ddfac7dc439`，canonical SHA `5ddfac7dc439afc45abdcf800b799c05d53704895b620d161ef08a442c55b2db`，Swift package `c6b6b2c00690998cfa9517374b9385f857cb3ee0efcbe3663f63ee76fee87959`，PC package `41332d093e652ec2de94f0f86b8f15107cd6f67f3b2e5ddec1c0685ab4d7d3be`，PC preview `d0c02be63dff3ab002dcf931ce7d0c5149152b78bea139fb1b0a2d86be196a18`。Swift `--mapcase02-suite` 与 Python 正式 MapCase02 测试直接断言这些值，且 Python production validator 必须接受原样 Swift 输出，不能只比较编译结果与自身 manifest。2026-08-10 的 Swift digest 更新来自手机预览 PNG 的 Y 轴镜像修复；canonical 和 PC 工件不变。上述 hash 只冻结标准工作簿链路，不能替代 exact-final-SHA CI 或产品资格。相同业务地图若原始文件名不同，canonical ID/SHA 可以相同，但 manifest 的 `source_file` 不同会产生另一个合法 package SHA；选择仍必须使用 exact ID/SHA。

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

## iOS 内嵌 Build Identity

`tools/Qualification/market_scanner_build_identity.py` 是 Xcode 脚本阶段、CI 和字节复核共用的唯一生成/验证入口。当前 `MarketScannerBuildIdentity` 为 version 4，必须精确包含 `format`、`version`、`app_git_sha`、`native_core_sha256`、`wave`、`branch`、`base_branch`、`base_sha`、`implementation_sha`、`validation_sha`、`build_configuration`、`working_tree_state`、`production_eligible`；多字段、少字段、JSON 重复 key 或任意字段格式错误均阻断构建/验证。

`wave`、`branch`、`base_branch` 只接受 `^[a-z0-9][a-z0-9._-]{0,127}$`，当前 RC `mobile-only-v1-release-candidate-blocker-closeout` 是合法值，不得再用历史 `mobile-only-v1r4-` 前缀判断当前 wave。`app_git_sha`、`base_sha` 及已绑定的 implementation/validation SHA 必须是 40 位小写十六进制，`native_core_sha256` 必须是 64 位小写十六进制。implementation/validation 提交尚未产生时，Python 生成/治理验证阶段分别只允许精确占位符 `<CODE_CONTRACT_TEST_BUILD_SHA>` 和 `<EVIDENCE_DOCS_SHA>`；任意其他占位文本均 fail closed。Swift `MobileBuildIdentity` 可加载该 exact schema 供诊断，但运行时 `isUsable` 要求 implementation/validation 两个字段均已绑定为 40 位小写 SHA；包含任一占位符的 App 都不得进入 eligible processing session。

普通共享 `RTABMapApp` scheme 的 Run、Profile 和 Archive 使用 Release；Test 和 Analyze 使用 Debug。两个配置现在都执行同一个 build-identity 生成与验证阶段，并进入同一套真实扫描、存储、finalization、处理和结果代码。Debug 使用 `--allow-dirty` 仅表示允许把当前 tracked tree 状态记录为 `dirty`，身份固定为 `production_eligible=false`；它不是跳过字段/schema/native digest 验证。`MobileBuildIdentity.canStartScan` 对合法 Debug/Release 均为 true，`isProductionQualified` 只对 clean Release 为 true。

功能测试可以手动选择 Debug：clean/dirty tracked tree 都会生成可用身份并允许完整扫描；配置页、`scan_events.jsonl` 和 finalized metadata 会保留构建配置、tree 状态和 production eligibility。真实性能、签名真机与现场资格仍应使用共享 `RTABMapApp` 默认 Run 或 `RTABMapApp-QualifiedDevice` 的 clean Release；Release 不使用 `--allow-dirty`，tracked 源码有未提交修改时构建继续失败。两种配置都要求治理 SHA、app SHA、native digest 和 exact schema 合法。

推荐真机步骤：

1. 功能端到端测试可选择 Debug；无需先提交 tracked 改动，但应在页面/日志确认其 `working_tree_state` 是否符合预期。
2. 性能或现场资格测试先提交本轮代码、测试和当前文档，确认 `git status --porcelain --untracked-files=no` 无输出，再选择默认 `RTABMapApp`（或 `RTABMapApp-QualifiedDevice`）Release。
3. 执行 Product → Clean Build Folder，然后 Run。
4. 从构建日志确认 `build identity verified`；Release 还应确认 `production_eligible=true`，Debug 应为 false。

命令行的等价无签名编译入口为：

```bash
xcodebuild \
  -project app/ios/RTABMapApp.xcodeproj \
  -scheme RTABMapApp-QualifiedDevice \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  clean build
```

手动 Debug 与 Release Run 使用同一 target 和 Bundle ID；再次安装任一配置都会替换设备上的另一配置，但两者都应包含 version 4 build identity。若设备端报告身份缺失或损坏，说明构建阶段未执行、旧 App 未被替换或 bundle schema 不匹配，应 clean build 后重新安装。Debug 可用 `--allow-dirty` 生成明确标记的测试身份；Release、Profile、Archive 和 QualifiedDevice 仍严格拒绝脏 tracked tree。资格验证只认 `production_eligible=true` 的 clean Release，但 Debug 不再因此失去完整功能。

## iOS native dependency cache

当前 iOS 构建把 device 与 simulator 视为两个不同的 native 平台，不再仅用 `arm64` 架构名判断兼容性：

```text
Libraries/iphoneos/        -> LC_BUILD_VERSION platform 2
Libraries/iphonesimulator/ -> LC_BUILD_VERSION platform 7
```

`install_deps.sh` 必须显式传入 `--platform iphoneos` 或 `--platform iphonesimulator`；未知值和缺失值直接失败。每个平台拥有独立的第三方源码、CMake build tree、install prefix、manifest 和 Actions cache。Xcode target 的 headers、frameworks 和完整 native link input 均通过 `$(PLATFORM_NAME)` 指向对应 prefix；旧的平铺 `Libraries/include`/`Libraries/lib` 不在当前链接合同内。Simulator 固定输出 arm64 slice，工程同时固定 simulator `ARCHS=arm64`，使 hosted builder 的 CPU 架构不会改变 Apple build gate 的链接目标。

hosted macOS CI 的两个 cache key 分别绑定平台、runner architecture、Xcode 版本、依赖脚本/policy/manifest 实现，以及 RTAB-Map 相关 CMake/corelib/utilite 输入树。cache miss 必须实际运行对应平台的完整 native dependency build；任一平台缺失都不能记为 skipped success。`ios_dependency_manifest.py` version 2 对该 prefix 下全部 `include`/`lib` regular files记录 bytes/SHA-256，并记录仍保留在 build tree 中的第三方 Git HEAD/patch 状态；同时直接解析 static archive、universal binary 和嵌套 VTK archive 中每个 Mach-O 对象的 `LC_BUILD_VERSION` 与 architecture。Device archive 出现在 simulator prefix、simulator archive 出现在 device prefix、缺失平台字段、存在无平台 Mach-O 对象、非 arm64 slice，或 CI 使用 legacy/unscoped prefix，都会 fail closed。无论 fresh build 或 restore，都先验证 manifest；cache miss 在验证成功后、App link 前保存对应 cache，随后分别执行 Debug simulator `clean build` 和 unsigned generic arm64 device `clean build`。

SwiftPM 依赖由共享 `Package.resolved` 固定到完整 40 位 revision。CI 首先在空 package cache 中用 `-onlyUsePackageVersionsFromResolvedFile` 冷解析，然后在 project metadata、simulator clean build 和 device clean build 后逐次与 checkout 时的锁文件做字节比较；Xcode 只要重写 lock，即使解析或编译本身成功，Apple build gate 仍直接失败，禁止用复制旧 lock 的方式掩盖漂移。

本机历史 `Libraries/` 仍可能保留早期 device-only 产物，但它不构成当前 simulator 验证证据。若尚未完成 `iphonesimulator` cold build，只能记录为“平台选路和合同测试通过、真实 simulator clean link 未执行”；不得用 `swiftc -parse`、缺依赖跳过、stub 或 device archive 代替 simulator build PASS。

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
