# 手机端测试计划（Mobile Test Plan）

> 状态：IMPLEMENTED（Swift host 单元/集成）；DEVICE/CI 阶段见 MOBILE_ONLY_CURRENT_STATUS.md

## 自动测试（已实现，Swift host 默认模式 + 模式化套件）

| 组 | 覆盖 | 状态 |
|---|---|---|
| I1-I14 | 三格式导入、canonical parity、公式/ZIP/CSV/JSON 安全 | Swift host + --import-suite |
| C5/C7/C9/C10 | 编译器路网统计、距离场 SHA、package self-load、PC parity | Swift host |
| P1/P2/P7/P8/P12 | Fast Path 收敛、快照事务、任务状态机 | Swift host |
| T1/T3/T4/T6/T7/T12 | 1 Hz 重采样、yaw 最短弧、lost/gap、100k 行 | Swift host |
| G1-G10 | 价签绑定/传播/融合/货架/质量门 | Swift host |
| X1-X9 | 工作簿结构、四表、公式注入、控制字符、100k | Swift host |
| P7R2-P7R6C 回归 | 既有三端套件 | 全量 unittest |

## 待执行（NOT RUN，未写 PASS）

- E2E-1 Replay（导入 sample.xlsx → 编译 → 处理 fixture session → 生成工作簿 → 校验 4 sheets）。
- E2E-2 三格式全流程一致性。
- E2E-3 真机短路线（5~10 分钟扫描、10 个价签、手机处理、手机导出）。
- E2E-4 Sam 路线（100+ truth tags、现场控制点）。
- Excel / Numbers / WPS 打开验证。
- 资源门：peak RSS、处理时长、thermal、磁盘、电量、中断/崩溃恢复。
