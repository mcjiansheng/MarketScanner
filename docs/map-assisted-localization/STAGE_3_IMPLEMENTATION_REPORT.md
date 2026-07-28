# 阶段三实现与验证报告

> 文档状态：**当前有效**。最后核对日期：2026-07-27。
>
> 结论限定：阶段三已形成安全的草稿/人工复核链路，但完整相对 SE(2) 因子图和正式发布能力尚未完成；正式 LiDAR iPhone 干跑与超市现场验收尚未执行，因此本报告不代表生产批准。

## 实现范围

- Map Studio 的“先验地图会话优化”先生成只读源库的优化副本，再读取 RTAB‑Map 全局优化位姿；源数据库处理前后以 SHA‑256 验证不变。
- 将 RTAB‑Map 优化轨迹对齐到单楼层地图坐标，再运行 x/y/yaw 有界平滑修正场。报告明确记录仅覆盖绝对约束的残差诊断、局部平移/yaw 形变和“无收敛证明”；不再把诊断值称为 solver objective，也不再称为完整 SE(2) 优化器。
- 输入在线结构约束、人工定位事件、人工锚点，以及只在既有轨迹已接近通道时生效的低权重道路区域/方向软约束；远端错误约束通过硬门限拒绝并进入审计。
- 根据离线轨迹修正价签坐标，重新关联稳定货架面 `A/B` 或柜台边 `E##`，输出 JSON、CSV、GeoJSON 和货架索引。
- 所有定位 JSONL 和最终价签先通过严格 contract；非法 UTF‑8、NaN/Infinity、format/version/身份/时间错误、超限、重复 ID 或必需文件缺失均阻断 current。
- 输出先写 `localized/.staging-*`，完整校验后成为不可变 `versions/vNNNNNN`，再原子更新 current。API artifact URL 绑定具体 version，读者不会混合两个版本。
- `manual_edits.json` v4 绑定 version 输入身份、地图、源/优化数据库、参数、工具和坐标契约；服务端生成 old value、UUID、UTC 和 base revision。所有编辑强制 version/revision CAS，冲突返回 409，失败重放不推进 current/revision。
- 会话输入按规范清单生成 `input_identity_id`，写入不可变 version；本机绝对路径按 identity 隔离。重放会重新验证 version 文件、local-input 身份和输入字节，防止旧版本悄然使用后来替换的会话文件。
- iOS 人工定位 v3 来自 native 原子 node/timebase/generation 快照；必需定位 sidecar 写失败会粘性阻断手机 finalized/eligibility，PC 对缺失健康证明的旧/损坏 prior-map 会话 fail closed。
- 当前只考虑单一楼层。楼层内部少量竖直位移保留在 RTAB‑Map 原始三维数据中，不参与二维先验地图 SE(2) 优化。

## 安全边界

- 该求解器是 `bounded_correction_field`，不是相对 SE(2) 因子图；`publish_gate` 固定加入 `solver_not_full_relative_se2_factor_graph`。
- 原始扫描数据库不做就地优化；处理产物只写入新输出目录。
- draft 可在 review gate 通过后生成新的 review 版本；publish 请求当前返回 422 且不写 `published.json`。
- 联动复核画布显示先验结构、在线/RTAB‑Map/离线三条轨迹和价签，支持按状态/货架筛选并从价签或问题带入编辑对象；对象 ID/JSON 保留为精确审计编辑，地图直接拖拽锚点仍属于可用性增强项。

## 自动验证

验证命令：

```bash
python3 -m unittest discover -s tools/PriorMap/tests -v
python3 -m unittest discover -s tools/SupermarketMapStudio/tests -v
python3 -m py_compile tools/PriorMap/*.py tools/SupermarketMapStudio/*.py
python3 tools/PriorMap/benchmark_stage3.py \
  --nodes 2000 --max-seconds 15 --max-peak-mib 64
node --check tools/SupermarketMapStudio/web/app.js
xcodebuild -project app/ios/RTABMapApp.xcodeproj \
  -scheme RTABMapApp -configuration Debug \
  -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build
git diff --check
```

自动测试覆盖地图包完整性、ARFrame→epoch node 时间基准和原子 native 快照、价签物理关联、严格 sidecar/capture-health、源库只读、输入身份、POSIX/Windows 不可变事务、版本/指针 durability 故障、双线程客户端同基准 CAS/409、服务端编辑审计以及 review/publish 硬门。

2026-07-27 本地 RepairV2 回归：PriorMap 95 项、Map Studio 60 项全部通过；Python 编译、JavaScript 语法、native symbol contract、Swift parse 和 `git diff --check` 通过；包含原子 native node/timebase bridge 与 sidecar health gate 的 generic iOS arm64 无签名 Release 构建 `BUILD SUCCEEDED`，仅保留工程既有的重复 asset/build script warning。GitHub workflow 另覆盖 Ubuntu、macOS、Windows 与 native/iOS 构建；远端结论以对应 Actions run 为准。

2,000 节点/20 约束最终基准耗时 3.509 秒、Python `tracemalloc` 峰值 0.562 MiB，低于 15 秒/64 MiB 门限。该数字只覆盖 `bounded_correction_field`，不代表 RTAB‑Map、地图生成、完整因子图或真机性能。

## 尚待完成

- 支持 LiDAR 的真实 iPhone 完整采集、扫码、弱纹理/动态行人、结束落盘和外部复制干跑；
- 正式超市单楼层现场精度与性能验收；
- 完整相对 SE(2) 因子图、真实 convergence/协方差/loop edge 和相应数值验收；
- 本轮已完成多智能体独立静态复审；发布前仍需外部/人工代码复核；
- 地图直接拖拽锚点和更丰富的批量编辑等非专业用户可用性增强。
