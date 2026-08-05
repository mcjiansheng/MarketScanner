# 手机后处理（Mobile Post Processing）

> 状态：IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED（P1/P2/P7/P8/P12）

## 模块

`app/ios/RTABMapApp/MobilePostProcessing/`

- `SessionSnapshotTransaction.swift`：finalized session → 私有只读快照（input_snapshot/ + 不可变 source DB 副本 + input manifest + bundle SHA）。
- `SE2FactorGraphCore.swift`：Fast Path 相对 SE(2) 因子图优化（Gauss-Newton + 稀疏阻尼 CG），bounded iterations、finite checks、确定性。
- `PersistentTaskCoordinator.swift`：`task.json` 状态机（原子写、crash recovery、interrupted ≠ completed）。
- `FinalTrajectory.swift` / `ClockCorrelationRecorder.swift`：最终轨迹与 1 Hz 重采样（见 FINAL_DEVICE_TRAJECTORY.md）。
- `TagObservationResolver.swift` / `ShelfAssociationEngine.swift`：价签最终定位（见 MOBILE_TAG_FINALIZATION.md）。

## Fast Path 安全

bounded iterations（60）、convergence tolerance、确定性稀疏 CG、每步 finite 检查、solver 失败抛错不发布。因子图输入为快照解析结果；处理只读快照，绝不处理原始 session 路径。

## 处理状态机

created → snapshotting → fast_optimizing → fast_quality_check → deep_reprocessing →
deep_optimizing → building_trajectory → resampling_trajectory → resolving_tags →
building_rescan_tasks → building_workbook → validating_result → committing_result → completed
（及 failed / cancelled / interrupted）

## 测试（Swift host）

- P1：小链 + 环闭合收敛，anchor 保持，漂移被拉平。
- P7：快照事务复制输入、bundle SHA 可复现、原始目录篡改不影响快照。
- P8：`task.json` 原子持久化 interrupted 状态。
- P12：completed 为终态，interrupted 可恢复。
