# Mobile-Only V1 产品契约

> 状态：**当前有效**；DESIGNED / IMPLEMENTED / HOST TESTED（本文档冻结产品边界与数据合同）
> 最后对齐：2026-08-10

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

### 2.3 Route A 冻结范围

Mobile V1 只承诺 `Fast reduced graph`，以及 Fast 质量失败后至多一次 `Full existing-graph optimization`；再次失败必须输出 `RESCAN_SESSION`。True sensor Deep（重新解码传感器并重建缺失视觉图证据）不属于 V1 功能，也不是本轮发布候选的隐藏 fallback。

### 2.4 单一生产入口与启动事务

- 首页“新建扫描”和菜单“开始门店扫描”必须先汇合到同一个轻量地图库选择页；只有用户明确选择一张地图后，才以 immutable `selectedMap` 创建同一个 `MobileScanSetupViewController`，再进入 `MobileOnlyWorkflowCoordinator` 和真实扫描 host。配置页不得自动加载 registry 第一张地图，也不得维护会触发重复完整校验的地图 picker。
- 手机 XLSX/CSV/JSON 编译包与正式 PC v2 package 只允许作为同一地图库的两种输入来源；注册后使用同一完整身份门和同一扫描配置。
- 地图/包读取、localizer 构造、会话目录和 native SQLite 初始化不得作为长任务运行在主线程。主线程只执行有界 UIKit、ARSession 和状态切换事务。
- workflow 进入 `.scanning` 前必须持久化完整 start receipt 和 workflow context。receipt 绑定 tracking session、segment、database、map/store/floor、启动状态、时间和 app SHA；context 绑定 receipt reference/SHA 和 scanning checkpoint。
- 首次相机权限必须在 workflow commit 前完成；`.notDetermined` 只能请求权限并重新进入完整校验，不能允许旧相机 callback 在 workflow 已失败后自行启动。
- 任何 host、receipt、context 或 cancellation 失败都必须有可调用 rollback，停止 mapping/camera/clock、清除 prior-map 状态、脱离失败数据库并释放 session identity。
- Test/Analyze 和手动 Debug build identity 继续 fail closed。正式扫描入口只接受满足 `MobileBuildIdentity.isUsable` 的构建；共享 `RTABMapApp` 默认 Run 与 `RTABMapApp-QualifiedDevice` 都使用 Release，不提供 dirty bypass，也不得放宽 runtime identity gate。

## 3. 手机导入（Track B1）

- 支持 `.xlsx` / `.csv` / `.json` 三种格式，从 Files 应用经 security-scoped document picker 选择。
- 正式 `Basic Info + Element Info` XLSX 从 `Basic Info` 取得 `storeCode`、`map_name`、画布和可选 scale；UI/CLI 门店与名称只能省略或作为 exact assertion，不能覆盖。CSV、legacy Element-only XLSX 与缺少内嵌 identity 的 JSON 仍必须显式提供 `store_id` 和地图名称。业务标识统一要求 NFC、非空、无首尾空白/控制字符/隐藏 basename/路径分隔符，`store_id` 最多 128 UTF-8 bytes，地图名称最多 200 UTF-8 bytes。
- 选中的文件通过 no-follow、regular-file、单 hardlink、前后 inode/size/mtime/ctime 一致性检查复制到 App 私有 staging；复制使用 bounded chunk、`O_EXCL`、data fsync 与 parent-directory fsync。后续不再读取 provider 原路径；复制失败只清理本次新建 staging 文件，不建立地图记录。
- 正式 workbook 解析为 canonical source v3 并编译为 package manifest v2。新生成 v2 的 `prior_map_id` 使用 lowercase、最长 115 字符的 ASCII slug 加 12 位 canonical SHA，最终路径 ID 不超过 128；Swift/PC 必须先过滤原始 Unicode 再做 ASCII lowercase。历史 v1 内容继续按冻结合同读取；pre-canonical uppercase v2 包只允许显式 diagnostic-only 完整性检查，普通 iOS/PC validator、旧向导、离线定位和 MobileMapLibrary 全部拒绝，不能隐式重写或复用 exact ID/SHA。旧包与无 generation 的旧开发 registry 必须保留原始证据并从原始地图重新导入。
- 坐标合同：源文件必须显式或通过用户预设得到 unit/origin/x_axis/y_axis/rotation。V1 提供两个用户可理解的预设：
  - 门店图：左上角为原点（unit=centimetre, origin=top_left, x=right, y=down, rotation=clockwise_degrees）
  - CAD 图：左下角为原点（origin=bottom_left, y=up）
- 三格式等价性：同一业务地图分别制作为 xlsx/csv/json 后，必须得到相同的 `canonicalSourceSha256`、元素清单、规范化坐标、楼层、货架、结构与路网语义。`sourceFileSha256` 允许不同。
- Canonical SHA 忽略：原始文件名、ZIP entry 顺序、XML attribute 顺序、CSV CRLF/LF、JSON key 顺序、非业务空白。
- 正式 XLSX 的 active production element 上限为 100,000；workbook sheets 与 relationships 各限制 4096 并使用线性 authority 索引；relationship/worksheet authority、XML namespace/父层级、row/cell reference、shared strings、公式、strict scalar、1 MiB cell 和角色几何全部 fail closed。

### 3.1 导入安全（冻结上限）

| 项 | 上限 |
|---|---|
| XLSX 文件 | 64 MiB |
| ZIP entries | 4096 |
| 总解压 | 256 MiB |
| 单 XML | 64 MiB |
| workbook sheets / relationships | 各 4096 |
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
- 生成层与安装层共享 `[a-z0-9._-]`、最大 128 字符的路径身份合同；`packageDirectory`、register、verify、registry read/rebuild 在写入或恢复前拒绝大小写折叠后相同但磁盘拼写不同的旧目录，不能让新 lower ID 写入旧 uppercase APFS 别名。
- `manifest.json` 必须绑定同一 `store_id` 和安全地图名称；`shelves.json` 使用 schema v2，每个物理货架段具有不可混用的 `shelf_segment_id`、start/end、longitudinal axis、front/back normal 与方向来源。`shelf_code` 只是显示标签，不是物理唯一键。
- 与 PC 编译器共享数据契约：元素 ID `f<floor>-r<row>`、六类元素（MapShelf/MapTable/MapPillar/MapTableFeature/MapCross/MapRoadPoint）、坐标变换 `x_m=x_cm/100; y_m=-y_cm/100; yaw_rad=-rotation_deg*pi/180`、路网统计、5 m 空间索引、距离场（0.40/0.20/0.10 m，2 m truncation，row_rle_u8_cm，per-level `data_sha256`）。
- 距离场 `data_sha256` 与 PC oracle 字节级一致（已验证 fixture 6 个 level 全匹配）。
- 原子提交：写 staging → fsync → 生成 package manifest → 用生产完整性校验器自检 → atomic rename；失败不覆盖旧地图。Registry rebuild 发现身份合法但内容损坏的包时，先生成并 fsync `quarantine_diagnostic.json` v2；诊断以 exact schema/canonical bytes 绑定 transaction ID、reason、Unix 时间、prior-map ID/SHA、源/隔离绝对路径、源目录模式、validator detail 和 payload tree SHA-256。payload 与诊断经同一 map quarantine root 下的 `.<transaction>.pending` / `.<transaction>.diagnostic.tmp` 事务发布，全部文件冻结为 `0444`、目录冻结为 `0555`。`register`、`unregister`、`listMaps`、exact map load 和 registry rebuild 均须在 library lock 下先扫描恢复：payload rename 前的 durable temp 保留源包并清理，payload rename 后完成诊断放置/冻结，publish rename 后补做 source/quarantine 相关父目录 `fsync`。未知名称、重复阶段、source/pending 冲突、缺失 payload、symlink/hardlink、非 canonical/越界诊断、权限或 payload hash 冲突一律保留现场并 fail closed；不得让生产 package 永久消失、让 hidden pending 进入 registry，或把已隔离 bytes 重新识别为生产地图。

## 5. 手机后处理（Track C/D/E）

- 处理只读私有快照（`SessionSnapshotTransaction`）：finalized session 复制到
  `Application Support/MarketScanner/Processing/<task-id>/input_snapshot/`，计算输入 manifest 与 bundle SHA；source DB 单独不可变副本。
- Fast Path：进程内相对 SE(2) 因子图优化（odometry / loop closure / prior-map constraints / road priors / accepted localization constraints），bounded iterations、finite checks、确定性稀疏 CG 求解、canonical factor digest；失败时只允许一次现有全图优化，solver fallback 不进入发布路径。
- Final trajectory：优化节点 → 1 Hz 重采样（ceil/floor UTC 秒，XY 线性、yaw 最短角、uncertainty 保守上界），跨 lost / disconnected / floor change / 超大间隔 / 时钟不连续输出 `UNAVAILABLE`。
- 当地时间：每行保留 `local_timestamp`（ISO 文本带 offset，如 `2026-08-05 21:06:23.000 +08:00`）、`utc_timestamp`、`unix_time_s`、`timezone_id`、`utc_offset`；业务主键用 `unix_time_s + sequence`。
- 价签 observation 只有属于 verified complete burst v2，且与 burst frame 构成 exact observation/frame 一对一关系时才可消费；解析全程 true streaming。共享 64 KiB JSONL reader 对每行 caller body 建立独立 autorelease pool，避免 Foundation 临时对象在 200k 规模长时进程中累积；保留值仍按正常强引用生存，UTF-8/duplicate-key/nesting/schema 严格性不得放宽或重复解析。最终定位按 exact `boundNodeID` 使用 `P_final = T_final_node * inverse(T_raw_node) * P_raw`，不再按 5 秒窗口猜节点。多帧证据融合为物理实例；货架结果同时输出 `shelf_segment_id`、`distance_from_shelf_start_cm` 与 `position_ratio`。
- `scan_events.jsonl`、clock、burst、trace 和其他证据均来自不可变 snapshot；坏行、缺 final newline、未知字段、身份/水位线不一致或 formal state 矛盾均 fail closed。scan event 的 `trackingSessionId` 必须逐行与当前处理 session 精确一致；当前 finalized metadata 尚未定义 scan-event count/last-ID，因此不得把 strict identity/framing 表述成 exact cardinality watermark。trace parser hard cap 为 2,000,000 records，产品资格 ceiling 为 48 h × 10 Hz = 1,728,000 records，两者不得混称。trace compactor 每秒保留保守最坏状态并保留 exact final sample；任何有限但无法安全映射到 `Int64` 秒轴或发生 subtraction overflow 的 timestamp 必须稳定返回 `compaction_axis_out_of_range`，不能 runtime trap。
- `localization_constraints.jsonl` 按 48 h × 2 Hz 资格规模覆盖 345,600 条正式决策，parser hard cap 为 400,000、单条 64 KiB、文件 768 MiB；constraint/manual/recovery 实际 JSONL 原始行数必须分别精确等于 `captureHealth.localizationConstraintRecordCount`、`captureHealth.manualLocalizationEventCount`、`captureHealth.localizationRecoveryEventCount`。完整且身份一致的 `accepted=false` 是非致命负证据，不产生 absolute prior；schema/identity/disposition 矛盾或无效 accepted record 仍阻断。manual v2/v3 均要求最近节点、第二候选间隔和 ISO/Unix 时间交叉核对。
- Native graph 的 skeleton/factor/prior 上限统一为 4096。Swift 先解析 disposition，再解释 error；`RESOURCE_REQUIRED` 保持资源暂停语义。C ABI v4 明确携带 quality byte count、runtime ABI、graph/factor SHA、factor/publish count；quality v2 必须作为完整 strict typed DTO 解析，并与 Fast/Full path、C disposition、request 的 map/SHA/session/projection policy、C trajectory/skeleton/publish/factor counts 精确一致。factor 数只认 `solver.factor_count`，RunSummary 不得使用宽松 JSON 数字强制转换或缺失字段 fallback。
- J-04 component identity 当前仍为发布 blocker：最终 DB 的 node `mapID` 和 links 足以推导 component，但现行 constraint schema 没有原子 bound node/map ID，manual v3 也没有 RTAB-Map map ID，reader 不得事后猜测或伪造“same component”。正确迁移需先升级写侧 node snapshot schema，再由最终 snapshot links 推导 component。
- 持久任务状态机：`task.json` 原子写入每个状态变化。cancelled / interrupted / resource_required / rescan_session / workflow_failed 先持久化并 fsync `terminal_state_intent.json`，再写 terminal `task.json`，最后删除 intent 并 fsync parent；任一 task 写入边界失败必须返回同时包含业务 outcome 与 durability failure 的 typed error，不得静默返回原业务终态。Route A 两次图路径仍失败或没有 publish-eligible trajectory node 时，必须使用稳定 `workflow.rescan_session_required`，将专用只读 `rescan_session_outcome.json` 以 file fsync + exclusive rename + parent fsync 发布在 task root，并在 checkpoint 中用 task-relative reference + SHA-256 绑定；terminal state/reason 固定为 `rescan_required` / `rescan_session_required`。artifact/checkpoint/task rename 已可见后的故障必须 stable no-follow 重读、补 parent fsync 并验证 exact task/session/map/input-bundle/outcome/SHA，不得被通用 failure terminalization 改写为 `.failed`。`publish_permitted` / `result_published` 只接受 JSON Bool；`no_publish_eligible_trajectory` 只接受 graph PASS，`graph_quality_failed` 只接受明确非 PASS graph disposition；numeric Bool、`RESOURCE_REQUIRED` 冒充 graph failure、EEXIST 不等价 winner、普通 Result 共存或多候选冲突均 fail closed。该 outcome 不是普通 Result，严禁发布 PriceTags、DevicePositions、workbook 或 Result entry。重启发现 artifact 与旧中间态并存时必须在 native 重跑前恢复该 outcome；terminal rescan task 不得原地重启。重启调和只允许精确 task identity + target state + reason 的幂等清除，或把已知非终态阶段推进到 intent 目标；completed、rescan_required、不同终态、同状态不同 reason 或 task identity 冲突必须保持 task/intent 原样并 fail closed，未调和的旧中间态不得普通 resume。恢复后进入 snapshot、正常 completion 或 committed-result completion 时必须显式清除旧 interruption/resource error。若连 intent 自身都无法在故障存储上建立，系统只能 fail closed 并报告 `establish_intent` durability failure，不能声称存在绝对可靠的磁盘恢复标记。所谓 resume 是重新验证并复用 exact immutable snapshot 后重新进入处理，不是从任意内存中间 stage 继续；terminal task 不得原地重启。

## 6. 手机导出（Track F）

- 生成真正 Open XML `.xlsx`（ZIP 包，含 `[Content_Types].xml`、`_rels/.rels`、`docProps/*`、`xl/workbook.xml`、`xl/worksheets/sheet1-4.xml`、`xl/styles.xml`）。
- 恰有四张业务表：PriceTags、DevicePositions、RunSummary、RescanRequired，列顺序固定。
- DevicePositions 一秒一行（≤1,048,576 行上限；超限失败并提示分 Session，不静默截断）；100,000 行可流式导出。
- 字符串一律 inline string，不生成 `<f>`；`= + - @` 开头内容加 `'` 前缀防公式注入；XML 控制字符过滤。
- 导出原子化（staging → rename）；workbook SHA 进入 result manifest。
- Result package 同时写 commit receipt；提交前 fsync 全部文件，将与 final path 同父目录的 `Results/.result-staging-<task-sha256>.<result-sha256>/` 隐藏 staging 先冻结为 files `0444` / root directory `0555` 并验证 exact set/modes，再通过 `renameatx_np(..., RENAME_EXCL)` 原子发布和 fsync parent。final path 从首次可见开始就不可写；rename 后必须重新验证 exact file set/modes、receipt、manifest 与逐文件 bytes/SHA-256。Result final rename 已可见后，任何 commit 尾部或 `completed` task write 故障都必须在通用 failure terminalization 前按 task ID + checkpoint 唯一 result ID 重验 committed receipt，并补做 Result/library parent fsync；真实 committed Result 只能保持 `committing_result` 等待重启调和或精确完成为 `completed`，严禁改写为 `failed` 或再次导出。receipt/manifest/identity 冲突、无效候选或同 task 多 Result 必须保留现场并 fail closed。rename 前失败不得创建 final path，冻结过的隐藏 staging 恢复为可清理模式；损坏或未知 root entry 移入 `Results/quarantine/quarantine-*/result_payload`，并写 durable `quarantine_diagnostic.json`，不得静默跳过或删除。

## 7. 状态词

`DESIGNED` / `IMPLEMENTED` / `UNIT TESTED` / `INTEGRATION TESTED` / `CI VERIFIED` / `DEVICE SMOKE PASS` / `SAM FIELD PASS` / `PRODUCTION QUALIFIED`。未执行不得写 PASS。

当前 RC closeout 仍是 **REJECTED / NO-GO / developer smoke only**：exact-final-SHA CI、两个 Apple 平台的完整 cold clean link、Replay/FAR、真机 Device Lab、Sam/现场资格均未完成。
