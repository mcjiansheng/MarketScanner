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
- `manual_edits.json` v3 绑定地图、源/优化数据库、参数、工具和坐标契约；服务端生成 old value、UUID、UTC 和 base revision。所有编辑强制 version/revision CAS，冲突返回 409，失败重放不推进 current/revision。
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

自动测试覆盖地图包完整性、ARFrame→epoch node 时间基准、价签物理关联、严格 sidecar、源库只读、不可变事务、版本/指针 fsync 故障、双线程客户端同基准 CAS/409、服务端编辑审计以及 review/publish 硬门。

2026-07-27 本地最终回归：PriorMap 72 项、Map Studio 59 项全部通过；Python 编译、JavaScript 语法、Swift parse 和 `git diff --check` 通过；包含 native node/timebase bridge 的 generic iOS arm64 无签名构建 `BUILD SUCCEEDED`，仅保留工程既有的重复 asset/build script warning。

2,000 节点/20 约束最终基准耗时 3.509 秒、Python `tracemalloc` 峰值 0.562 MiB，低于 15 秒/64 MiB 门限。该数字只覆盖 `bounded_correction_field`，不代表 RTAB‑Map、地图生成、完整因子图或真机性能。

## 尚待完成

- 支持 LiDAR 的真实 iPhone 完整采集、扫码、弱纹理/动态行人、结束落盘和外部复制干跑；
- 正式超市单楼层现场精度与性能验收；
- 完整相对 SE(2) 因子图、真实 convergence/协方差/loop edge 和相应数值验收；
- 本轮已完成多智能体独立静态复审；发布前仍需外部/人工代码复核；
- 地图直接拖拽锚点和更丰富的批量编辑等非专业用户可用性增强。
