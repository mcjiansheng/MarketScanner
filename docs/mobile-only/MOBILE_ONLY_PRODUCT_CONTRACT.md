# Mobile-Only V1 产品契约

> 状态：DESIGNED / IMPLEMENTED（本文档冻结的产品边界与数据合同）
> 最后对齐：2026-08-05

## 1. 目标

最终用户从原始地图（XLSX / CSV / JSON）到最终 XLSX 工作簿的完整流程在 iPhone 上闭环，全程不要求使用 PC：

```text
原始 XLSX/CSV/JSON
→ iPhone 导入
→ iPhone 地图编译
→ iPhone 扫描
→ iPhone 最终处理
→ iPhone XLSX 导出
```

## 2. 产品边界

### 2.1 最终用户不得依赖 PC

生产 App 运行时不得调用 Python、subprocess、外部 CLI，不得要求 Map Studio、不得要求把 session 复制到电脑、不得要求电脑生成 PriorMap 或 XLSX。

### 2.2 无人工编辑

系统对每个价签只输出三种结论：`ACCEPTED`、`RESCAN_REQUIRED`、`UNAVAILABLE`。不确定结果进入补扫任务，不允许静默猜测，不允许用户手工拖动修复。

## 3. 手机导入（Track B1）

- 支持 `.xlsx` / `.csv` / `.json` 三种格式，从 Files 应用经 security-scoped document picker 选择。
- 选中的文件立即复制到 App 私有 staging 目录，对复制后的稳定文件计算 SHA；后续不再读取 provider 原路径；复制失败不建立地图记录。
- 三格式解析后统一为 `MarketScannerPriorMapSource` v1（`format = "MarketScannerPriorMapSource"`、`version = 1`）。
- 坐标合同：源文件必须显式或通过用户预设得到 unit/origin/x_axis/y_axis/rotation。V1 提供两个用户可理解的预设：
  - 门店图：左上角为原点（unit=centimetre, origin=top_left, x=right, y=down, rotation=clockwise_degrees）
  - CAD 图：左下角为原点（origin=bottom_left, y=up）
- 三格式等价性：同一业务地图分别制作为 xlsx/csv/json 后，必须得到相同的 `canonicalSourceSha256`、元素清单、规范化坐标、楼层、货架、结构与路网语义。`sourceFileSha256` 允许不同。
- Canonical SHA 忽略：原始文件名、ZIP entry 顺序、XML attribute 顺序、CSV CRLF/LF、JSON key 顺序、非业务空白。

### 3.1 导入安全（冻结上限）

| 项 | 上限 |
|---|---|
| XLSX 文件 | 64 MiB |
| ZIP entries | 4096 |
| 总解压 | 256 MiB |
| 单 XML | 64 MiB |
| 行 | 500,000 |
| 单 cell | 1 MiB |
| shared strings | 1,000,000 |
| CSV 字段 | 4 MiB |
| JSON 文档 | 64 MiB |
| JSON 深度 | 64 |
| 元素数 | 100,000 |

XLSX 的 `floor` / `element` 单元格使用公式一律拒绝（`map_source_formula_not_supported`）。ZIP 禁止 path traversal / absolute entry / `../`，限制压缩比（200:1）防御 zip bomb。CSV 必须 RFC 4180 流式解析（quoted comma / quoted newline / `""` escape / CRLF / LF / BOM）。JSON 复用严格解析器（UTF-8、无重复 key、无 NaN、深度与大小限制）。

## 4. 手机 PriorMap 编译器（Track B2）

- 输入 canonical source，输出自校验 prior-map package（元素/货架/固定结构/路网/空间索引/距离场/预览/manifest/validation report/package manifest）。
- 与 PC 编译器共享数据契约：元素 ID `f<floor>-r<row>`、六类元素（MapShelf/MapTable/MapPillar/MapTableFeature/MapCross/MapRoadPoint）、坐标变换 `x_m=x_cm/100; y_m=-y_cm/100; yaw_rad=-rotation_deg*pi/180`、路网统计、5 m 空间索引、距离场（0.40/0.20/0.10 m，2 m truncation，row_rle_u8_cm，per-level `data_sha256`）。
- 距离场 `data_sha256` 与 PC oracle 字节级一致（已验证 fixture 6 个 level 全匹配）。
- 原子提交：写 staging → fsync → 生成 package manifest → 用生产完整性校验器自检 → atomic rename；失败不覆盖旧地图。

## 5. 手机后处理（Track C/D/E）

- 处理只读私有快照（`SessionSnapshotTransaction`）：finalized session 复制到
  `Application Support/MarketScanner/Processing/<task-id>/input_snapshot/`，计算输入 manifest 与 bundle SHA；source DB 单独不可变副本。
- Fast Path：进程内相对 SE(2) 因子图优化（odometry / loop closure / prior-map constraints / road priors / accepted localization constraints），bounded iterations、finite checks、确定性稀疏 CG 求解、canonical factor digest；solver fallback 不进入发布路径。
- Final trajectory：优化节点 → 1 Hz 重采样（ceil/floor UTC 秒，XY 线性、yaw 最短角、uncertainty 保守上界），跨 lost / disconnected / floor change / 超大间隔 / 时钟不连续输出 `UNAVAILABLE`。
- 当地时间：每行保留 `local_timestamp`（ISO 文本带 offset，如 `2026-08-05 21:06:23.000 +08:00`）、`utc_timestamp`、`unix_time_s`、`timezone_id`、`utc_offset`；业务主键用 `unix_time_s + sequence`。
- 价签最终定位：`P_final = T_final_node * inverse(T_raw_node) * P_raw`；多帧 burst 融合为物理实例（`tag_instance_id`，同 barcode 不同楼层/货架保持独立实例）；货架关联输出 `distance_from_shelf_start_cm` 与 `position_ratio`；自动质量门输出 `ACCEPTED` / `RESCAN_REQUIRED`。
- 持久任务状态机：`task.json` 原子写入每个状态变化；App 重启后可继续或安全重启；interrupted 永不显示为 completed。

## 6. 手机导出（Track F）

- 生成真正 Open XML `.xlsx`（ZIP 包，含 `[Content_Types].xml`、`_rels/.rels`、`docProps/*`、`xl/workbook.xml`、`xl/worksheets/sheet1-4.xml`、`xl/styles.xml`）。
- 恰有四张业务表：PriceTags、DevicePositions、RunSummary、RescanRequired，列顺序固定。
- DevicePositions 一秒一行（≤1,048,576 行上限；超限失败并提示分 Session，不静默截断）；100,000 行可流式导出。
- 字符串一律 inline string，不生成 `<f>`；`= + - @` 开头内容加 `'` 前缀防公式注入；XML 控制字符过滤。
- 导出原子化（staging → rename）；workbook SHA 进入 result manifest。

## 7. 状态词

`DESIGNED` / `IMPLEMENTED` / `UNIT TESTED` / `INTEGRATION TESTED` / `CI VERIFIED` / `DEVICE SMOKE PASS` / `SAM FIELD PASS` / `PRODUCTION QUALIFIED`。未执行不得写 PASS。
