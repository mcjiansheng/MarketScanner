# 最终设备轨迹（Final Device Trajectory）

> 状态：**当前有效**；IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED。最后核对：2026-08-07。

## 三种时间

- monotonic：计算主时间轴。
- UTC：跨系统身份与 1 Hz 重采样网格。
- local：业务输出（每行保留 local_timestamp / utc_timestamp / unix_time_s / timezone_id / utc_offset）。

## 时钟相关性记录

`clock_correlations.jsonl` 记录时机：session_start、每 30 秒、will_resign_active、did_become_active、system_clock_change、timezone_change、session_end。writer 使用 `O_CREAT|O_EXCL|O_NOFOLLOW` 增量 JSONL append，每 64 条 fsync；durable watermark 只在 fsync 成功后推进，结束时 flush 最后不足一批的记录并 fsync parent。60,000 node-binding host 场景验证 writer 不保留全量 binding 数组。每次系统时钟/时区变化建立新 correlation segment，严格 reader 拒绝 backward/non-injective UTC、未知 reason、count/watermark/line-number 漂移。monotonic → UTC 映射为分段线性（不推断样本范围外的值）。

## 1 Hz 重采样

- 范围：`ceil(session start UTC second)` → `floor(session end UTC second)`，每秒一行。
- 插值：XY 线性；yaw 最短角；uncertainty 保守（取前后上界）。
- native uncertainty 缺失时保持缺失并输出 `UNAVAILABLE`，不得伪造 `0.0`。
- 禁止跨：disconnected graph、lost interval、session interruption、floor change、>3 s 节点间隔、时钟不连续 —— 该秒输出 `UNAVAILABLE`（保留行）。
- 业务主键：`unix_time_s + sequence`，不用 local timestamp。

## DevicePositions 列（固定顺序）

sequence / local_timestamp / utc_timestamp / unix_time_s / timezone_id / utc_offset /
session_elapsed_s / store_id / floor_id / map_x_m / map_y_m / yaw_deg / position_status /
position_source / before_node_id / after_node_id / interpolation_ratio /
localization_confidence / estimated_uncertainty_m / tracking_state /
graph_quality_status / prior_map_id / prior_map_sha256 / tracking_session_id / app_git_sha

## 测试（Swift host）

- T1：基本 1 Hz（整秒落在节点之间时插值、时间戳/时区/offset、前后节点绑定、保守 uncertainty）。
- T3：yaw 跨 ±π 最短弧。
- T4：lost interval 与超大节点间隔输出 UNAVAILABLE。
- T6/T7：单一 correlation 段映射。
- T12：100,000 行工作簿导出。

正式 localization trace 使用 strict streaming parser：坏行、未知字段、formal state 矛盾、时间/offset 恒等式错误和 count mismatch 全部阻断。安全 hard cap 为 2,000,000 records，当前资格 ceiling 为 1,728,000 records；本地 100k finalization 内存场景在独立进程中维持 256 MiB 固定门。
