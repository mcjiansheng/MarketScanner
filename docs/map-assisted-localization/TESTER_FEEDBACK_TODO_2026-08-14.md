# 现场测试反馈整改与待办

> 文档状态：**当前有效**。最后核对日期：2026-08-17。

本文记录 `fix/manual-anchor-continuous-recovery@bb09e1346a13945b1d4d8fa7eaf174959b528ab9` 的现场反馈，以及后续 `fix/tag-node-local-publication-gate` 设计审查整改。它不把“移除了已知 trap”写成“4 次现场 crash 已根治”，也不把未经同一真实 Sam 数据 A/B 的参数建议直接固化为生产默认值。

## 通道/货架物理约束设计审查整改状态

- **P0 坐标框重复变换：代码与自动化已关闭。** 新 observation v2 保存 exact-bound-node local 3D，手机/PC 使用 `P_final=T_final_node×P_node`；历史 v1 清空可发布坐标并要求重扫。尚缺签名真机、非零初始地图位姿、人工重定位/真实 loop correction 和货架控制点共同组成的现场端到端精度证明，因此不能把“算法错误已修”扩大为“最终价签现场精度已合格”。
- **P1-A 发布门漏检：代码与自动化已关闭。** coordinate contract v2 把 degradation、coordinate audit、legacy、低置信、空坐标、未关联和 rescan 全部纳入 `COMPLETE/publish_permitted`，并在结果读取/任务恢复时二次验证。
- **P1-B～P1-E 与 P2 已进入代码但仍未关闭资格。** manifest v5、epoch/component、通道/货架/侧状态、手机点+扫掠线段 free-space、PC shelf factor 和 concrete shelf loop 已有严格实现；2026-08-17 sidecar v2 又关闭了“当前位置附近货架自证”和普通视觉 loop 指标冒充货架几何证据的问题，并持久化 LOW_CONFIDENCE 原因。后续代码审查继续修复了固定 top-3 冒充 24→12、拓扑不可达 top1 下一帧自洗白、重复 node binding 重置窗口、降频后用稀疏 node span 低估动态占比、无关 RTAB loop 引用旧窗口，以及当前 shelf/side 残留。尚未关闭的阻断是：跨 epoch 缺少 native 多链路共识正向 bridge、C-1/C-2/C-3 真机标定、24→12→降频性能链的真机证据、动态顾客/购物车与 `map_mismatch` 现场矩阵。publication invariant v3 允许 Debug + `CALIBRATION_PENDING` 在其余真实质量门通过时保留 `COMPLETE/TEST` 全量成果，但固定 `production_publish_permitted=false`；PC 正式 current publication 和 clean Release 的生产资格仍显式阻断该状态，TEST 结果不能被提升为正式生产发布。

## 本轮已确认并修复的关键问题

- 人工“重新选择位置”改用真正的 `UIScrollView` 1×–8× 缩放、放大后单指平移、双击缩放/复位、箭头定位、点击选点和箭头拖动。旧实现直接修改 `imageView.transform`，但坐标换算继续使用未变换 bounds，且 `layoutSubviews()` 会重设 frame，确实会造成缩放/平移无效或选点偏差。
- 保留 canonical X/Y/yaw 数值、0.1/0.5/1.0 m 四向微调、东/北/西/南和 ±1/±5/±15° 旋转。确认前显式结束编辑并重新解析三个字段；非法输入保留在弹窗内，不再静默提交旧 pose。
- 人工定位改为 fresh-node 握手：确认后保持弹窗，在请求后的 accepted frame 上重新取得与 node stamp 相差不超过 250 ms 的 exact snapshot（优先新 node；刚发布的同一 node 仍可用，避免强迫静止用户移动）；超时只提示重试，用户已选坐标不丢失。移除“弹窗先关闭，再依赖最多 1 秒旧缓存”的低成功率路径。
- 人工 alignment 改为 `prepare -> durable manual event -> compare-and-swap commit`。审计 JSONL 写失败时 live alignment 保持不变；不再出现“内存位置已改变，但事件未落盘”的不可审计状态。
- RTAB-Map、prior-map depth/localizer、ESL depth/ray 和 location-bearing sensor boundary 统一使用同一帧经连续性门接受的 software-stabilized transform。被拒 raw frame 只进入 tracking health 统计，不进入位置 sidecar。
- tracking 恢复后的 raw ARKit epoch 若发生明显坐标变化，先重基准并拒绝边界帧；普通 callback gap 的位移/转角门不再随 2 秒放宽到 6 m/360°，而使用 0.25 秒封顶的连续性窗口，并记录 `poseEpoch`、距离、角度和实际门限。
- 连续扫描 `RGBD/OptimizeMaxError=2.0` 和 `Vis/MinInliers=40` 明确成为当前唯一运行 authority，实际值、用户设置值和 profile 名写入 `scan_events.jsonl`；Debug 拒绝提示显示实际值。此项只修复“设置显示与运行值冲突”，没有在缺少 Sam 假闭环 A/B 时擅自改为 4.0。
- 接入 MetricKit crash/hang/CPU/disk-write diagnostics。活动 tracking session 与本地 session root 在异常退出后保留，并在下次进程启动时转入 pending abnormal context，避免后续新扫描覆盖旧 crash 归属；iOS 后续交付的 payload 以有界 JSONL 写入全局诊断目录和本地 `segment_0001`。8 MiB 内完整保留原始 call tree；单记录超限时保留计数、原始大小和明确省略原因。Map Studio API 只返回有界 crash/hang 摘要。

## P1：必须继续关闭，但不能在本轮伪称完成

### 1. 现场 crash 根因与真机稳定性

- 从测试设备收集 4 次异常对应的 `.ips`、MetricKit payload、App Git SHA、iOS build、设备型号、热/内存/磁盘、最后 200 条 `scan_events.jsonl`，完成符号化和共同栈归类。
- 在 exact-final-SHA 签名构建上执行冷启动、刚开始扫描、长扫、前后台、相机/电话中断、低内存、thermal serious、Files provider 和价签 Vision 并发矩阵；至少完成 2 小时 Sam 路线 soak 与 20 次短扫启动/停止循环。
- 只有复现栈被代码修复且同条件不再出现，才能把对应 crash 标为 closed。当前只能表述为“已移除若干已知 trap并补足诊断”，不能表述为根因已证明解决。

### 2. crash/kill 后继续同一业务任务

- 当前正常 Stop、同进程系统中断恢复和原始未完成会话保留已实现；冷启动后安全续写同一业务任务仍未完成。
- 不允许直接重开旧 SQLite writer 并假定 ARKit 世界坐标连续。正确产品语义应验证 receipt/checkpoint/DB/map identity，把旧 epoch 只读封存，再创建新的 tracking epoch/child capture，通过人工 fresh-node 锚点或正式 shelf-loop 证据连接；无法连接时也必须允许分别处理、导出和人工合并。
- Coordinator 需要显式“继续该任务 / 封存并新建 / 仅导出恢复包”状态和幂等事务；任何选择都不能删除旧 DB、价签或 sidecar。

### 3. Sam 长货架在线闭环召回与资源恢复

- WM→LTM/SQLite 是持久转移，不等于数据删除；但在线 loop candidate 的召回窗口、`MaxRetrieved` 和工作内存仍会影响绕大货架一圈后的即时闭环。
- 当前内存/热策略只降低 WM/render window，不带滞回恢复。需要记录 target/applied WM、降级原因、LTM retrieval 数、候选 node span 和 loop span，并在资源稳定多个 checkpoint 后分级恢复；thermal 与 memory 两条策略必须合并为一个 authority。
- 使用同一批真实 Sam 数据对 300/500/800 WM、`MaxRetrieved=3/5`、不同 detection rate 做闭环召回、假闭环、峰值 RSS、温度、电量和数据库吞吐 A/B。没有这些证据前不直接把 500 或 800 写成生产默认值。

### 4. 闭环参数 A/B，而不是经验值覆盖

- 对 `OptimizeMaxError=2.0/4.0`、`LoopThr=0.15/0.18/0.20`、`Vis/MinInliers=40/30` 使用同一真实 Sam 原始 DB、人工控制点和假闭环标签执行离线/在线对照。
- 指标至少包括真闭环召回、假闭环率、最大相邻位姿梯度、全局控制点误差、处理耗时和现场 HUD 可解释性。只有冻结证据通过后才新增“大货架场景 preset”；Settings 中不得继续显示一个运行时会被 profile 覆盖却无说明的值。

### 5. 正式 capture-pose epoch 和 concrete shelf-loop

- 本轮统一了同帧 transform authority并记录 discontinuity event，但 `poseEpoch` 尚未进入 localization trace、tag observation、trajectory 和 session input manifest 的正式逐记录身份。
- 后续 schema 必须把 epoch、raw/corrected transform、边界原因和 node/time 范围绑定到 immutable input；PC/手机 parser、watermark、mutation test 和结果 manifest 同步升级。
- 当前回环附近 top-5 shelf candidate 仍是 diagnostic-only。正式货架闭环必须完成 session input manifest v5/J-04：回环前后 exact node/time 窗口、货架/地面点、phone↔shelf SE(2)、distance-field SHA、候选 margin、资源上限和跨端严格 parser，不能把邻域候选直接当绝对因子。

### 6. 动态顾客/购物车与碰撞恢复

- 结构覆盖/匹配增加 temporal persistence、multi-view consistency、人体/大动态区域抑制和短时体素衰减；动态物体只能降低结构置信度，不能形成长期货架证据。
- 碰撞后结合 ARKit tracking、IMU 角速度、raw/corrected epoch、地图结构残差和后续闭环判断；边界帧不得进入 graph/prior/ESL，后续稳定帧继续采集，不能因一次冲击终止任务或删除节点。

## P2：合理但非阻断项

- 地图导入成功后某些路径可能停在 `mapReady`，需补自动进入统一 setup 的状态机测试与可取消性。
- 历史导出目标若位于源 session 内部或其后代，需做祖先/后代关系拒绝，避免递归复制。
- Windows `prior_map_compatibility.py` 对只读 descriptor 调用 `fsync` 可能返回 `Bad file descriptor`，应按平台和访问模式区分。
- raw VIO reset 证据目前可能按 Link type 计数，同一 node pair 的多种 Link 不能充当多个独立 reset 约束。
- MetricKit 已由 PC API 解析，但 Web UI 尚未提供 crash/hang 卡片、原始诊断文件打开入口和自定义 Files provider 会话的诊断打包；补充时不得把 CPU fallback 或“无 payload”显示成无 crash。
- 人工定位需在真机验证 VoiceOver、Dynamic Type、横竖屏、键盘遮挡、缩放后箭头 hit target 和双指旋转/缩放冲突；必要时将两指旋转改为显式方向旋钮，但 canonical 数值与离散按钮必须保留。
- 启动前“传感器校准”只做 1–2 秒 soft readiness（tracking normal、重力/角速度稳定、sceneDepth/内参/曝光可用），不得伪装成第三方 App 能重做陀螺仪硬件标定，也不得在主线程 sleep 或先建 DB 后等待。

## 关闭条件

- 自动化：PriorMap、Map Studio、Qualification、native、Swift parse、Python/JavaScript syntax、macOS `rtabmap-reprocess` 和 unsigned exact-HEAD iPhoneOS Debug/Release 全部通过。
- 真机：fresh-node 人工重定位连续 20 次成功，含 X/Y/yaw 文本最后一键确认、缩放/平移、弱 tracking 恢复和审计写失败注入；成功记录必须证明 UI 值、manual event、live alignment 和 PC 解析一致。
- 现场：Sam 大货架完整绕行、顾客碰撞、长距离漂移、人工校准、可靠/错误回环隔离均保留完整 DB/节点/价签和最终低置信度结果；没有完全性损坏时不得只返回“处理失败”。
- 发布：exact SHA、签名设备、原始证据包和独立审查齐全前，状态保持 **NO-GO / NOT PRODUCTION READY**。
