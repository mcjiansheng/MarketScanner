# 手机 PriorMap 编译器（Mobile Prior Map Compiler）

> 状态：**当前有效**；IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED（C5/C7/C8/C9/C10 + MapCase02）。最后核对：2026-08-09。

## 模块

`app/ios/RTABMapApp/MobilePriorMapCompiler/`

- `MobilePriorMapCompiler.swift`：canonical source → prior-map package（staging → 自检 → atomic rename）。
- `MobileDistanceFieldBuilder.swift`：多分辨率距离场（0.40/0.20/0.10 m、2 m truncation、row_rle_u8_cm、per-level `data_sha256`），与 PC `distance_field.py` 字节级一致。
- `MobileRoadGraphBuilder.swift`：路网（crosses/nodes/edges/连通分量/孤立节点统计）与 5 m 空间索引，与 PC 一致。
- `MobilePackageManifestBuilder.swift`：`package_manifest.json`（artifacts + `package_sha256`），与 PC `package_digest` 一致。
- `MobilePreviewRenderer.swift`：CoreGraphics 渲染真实 PNG 预览（preview.png + preview_floor_*），只服务展示，不参与定位数学。

## 编译产物

`manifest.json` / `elements.json` / `shelves.json` / `fixed_structures.json` /
`road_graph.json` / `spatial_index.json` / `distance_fields.json` / `preview.png` /
`preview_floor_<NNN>_<floor>.png` / `validation_report.json` / `package_manifest.json`

`manifest.json` 必须包含通过统一业务标识策略的 `store_id` 与 `name`。手机 XLSX/CSV/JSON 导入和 PC `xlsx_to_prior_map.py` 均要求显式门店 ID；不得从文件名或旧 registry 隐式猜测门店。

新生成的 `prior_map_id` 使用跨端统一的 canonical lowercase slug：先在原始 Unicode 名称上只保留 ASCII `A-Z/a-z/0-9/._-`，再仅映射 ASCII 大写，主体截断到 115 字符，最后追加 `-` 和 canonical/source SHA 前 12 位，保证最终不超过 MobileMapLibrary 的 128 字符上限。普通 Swift/Python 完整性校验、旧 iOS `PriorMapPackage.load` 向导和 PC 离线定位都默认拒绝 pre-canonical uppercase v2 package；仅显式 `allowLegacyV2IdentifierForDiagnostics` / `--allow-legacy-v2-identifier-for-diagnostics` 可做只读诊断，不能加载、注册或定位。若磁盘存在与新 ID case-fold 相同但拼写不同的旧目录，写入前明确提示重新导入。

## 六类元素

MapShelf（货架）/ MapTable（桌）/ MapPillar（柱）/ MapTableFeature（桌台特征）/ MapCross（道路线）/ MapRoadPoint（道路点）。
货架/桌/柱/桌台特征为结构体（参与距离场与空间索引），MapCross/MapRoadPoint 构成路网。

`shelves.json` 当前为 schema v2。每个货架物理段以 `shelf_segment_id` 唯一标识，并携带 start/end、longitudinal axis、front/back normal、side semantics version 和 orientation provenance；相同 `shelf_code` 的不同段不得合并或覆盖。loader 与 compiler 同时按 v2 验证，旧 v1 只作为明确的历史兼容输入处理。

正式 workbook 生成 package manifest v2。完整性入口不信任重签后的派生 JSON：它从 active `elements.json` 重算 canonical identity、road graph、spatial index、distance fields 和 shelf segments，并精确比较；role/kind/point-count/nondegenerate、source coordinate、统计、ID 与 strict scalar 任一不一致均拒绝。距离场在 spatial grid 前构建并在任何 `Double→Int`/RLE 分配前执行单维 20,000、单层 8,000,000、包总计 16,000,000 cells 上限。

## 坐标变换（冻结）

```text
source: unit=centimetre, origin=top_left (或 bottom_left), x=right, y=down(或 up), rotation=clockwise_degrees
map:    unit=metre, x=right, y=up, yaw=counter_clockwise_radians
transform: x_m = x_cm/100; y_m = -y_cm/100 (top_left) 或 +y_cm/100 (bottom_left); yaw_rad = -rotation_deg*pi/180
```

## 测试（Swift host）

- C5：路网统计与 PC oracle 一致（cross/node/edge 数、连通分量、孤立节点）。
- C7：距离场 per-level `data_sha256` 与 PC oracle 一致（fixture 6 level 全匹配）。
- C9：编译产物通过生产快照读取器自检（package self-load）。
- C10：三格式 canonical parity 基础上的编译语义 parity。
- MapCase02：Swift package self-load、重签 canonical/graph/spatial/distance/shelf mutation、strict bool/integral-float v1/v2 manifest/report count、legacy v1 statistics/visible/hidden 派生、warnings/malformed array、OOM/overflow budget、duplicate element ID typed rejection，以及 MobileMapLibrary install/register/list/exact-read；`validation_report.summary` 的 `node_count`/`edge_count` 必须精确绑定 road graph，并由 Python production validator 直接复核 Swift 包。canonical ID `piaseczno-5ddfac7dc439`，冻结 package SHA `8d3564ce68aadb087a2820a02b4747d15ea1f4d22b14e8776f913d33775b1b84`。重签为旧 uppercase v2 ID 后，production validator 必须拒绝，显式 diagnostic-only validator 必须保留只读完整性结果。
