# Mobile-Only V1 当前状态

> 更新：2026-08-05（实现 + 单元/集成测试阶段）

## 总体

分支 `mobile-only-v1-end-to-end-integration`，基线 `04cdfe9a4c533908d1eb175ba84e3e39d2ca2654`（P7R6C HEAD）。

## 已交付（IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED）

- Track B1 手机导入：XLSX/CSV/JSON → `MarketScannerPriorMapSource` v1；canonical parity；导入安全（ZIP/公式/CSV/JSON 防御）；错误码冻结。
- Track B2 手机编译器：prior-map package 全产物；距离场 `data_sha256` 与 PC oracle 字节级一致；原子提交 + 生产自检。
- Track C 后处理：session 快照事务；Fast Path 相对 SE(2) 因子图；持久任务状态机。
- Track D 轨迹：时钟相关性记录；1 Hz 最终轨迹（本地时间 + UTC + offset；UNAVAILABLE 区间）。
- Track E 价签：节点/时间绑定、位置传播、burst 融合、货架关联、自动质量门。
- Track F 导出：真 Open XML XLSX 四表流式导出、公式注入/控制字符防护、原子导出。
- UI 接线：MapSourceDocumentPicker（security-scoped staging）、ResultShareController。
- 工程登记：project.pbxproj（31 个新文件四段）、CI swiftc -parse 列表、Swift host 编译列表。
- 修复 P7R6C 遗留缺陷：Swift host 默认模式 guard 从 `arguments.isEmpty` 修正为 `count <= 1`（C1/C2 此前未真正执行）。

## 未执行（NOT RUN，禁止写 PASS）

- exact-SHA CI（含新增 iOS 文件的全量 job）。
- Xcode clean build 与 unsigned arm64 build。
- Replay / 三格式 E2E（Python 驱动 + host 模式化套件已完成基础设施）。
- 真机短路线 / Sam 路线 / Excel-Numbers-WPS 打开验证。
- 独立 reviewer 只读审查。
- Deep Path（native RTAB-Map 重处理桥接）为 DESIGNED，尚未接线。

## 决策

本阶段结论：**DESIGNED / IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED（Swift host）**；
NOT CI VERIFIED / NOT DEVICE SMOKE PASS / NOT SAM FIELD PASS / NOT PRODUCTION QUALIFIED。

## V1R1 收口（见 MOBILE_ONLY_V1R1_PRODUCT_INTEGRATION.md）

分支 `mobile-only-v1r1-product-integration-closeout` 新增：
真实 App UI 与总协调器（Gate A）、严格导入/canonical v2（Gate B）、
in-process RTAB-Map 图读取 bridge（Gate E）、流式原子 XLSX（Gate J）、
Replay E2E、CI 分支匹配。当前状态与未执行项见 V1R1 文档。
