# 地图辅助定位变更记录

> 文档状态：**当前有效**。最后核对日期：2026-07-24。

## 2026-07-24 — 阶段二

- 根据综合代码审查改为全搜索窗多盆地传播和真实次佳唯一性；缺少第二候选时保守拒绝，新增周期结构负例。
- 时序门控改为比较 `best ⊖ raw` 校正变换；Python 回放同步实现两帧门控、gain、锚点更新、状态迟滞和 tracking 恢复。
- 解码固定结构；货架/柜台可关联，柱体和全部结构参与最近遮挡判断，被其他结构挡住时不预选远端结构。
- Vision 使用捕获时对齐快照/版本和四方向 ROI；楼面估计加入法向、残差、内点率和时序稳定性。
- finalization 开始即失效并有界 drain 定位任务；定位写入校验 tracking session/finalizing 且不再隐式创建会话。
- 地图包新增三层确定性结构距离场、RLE、逐层 SHA‑256 和 PC/iOS 完整性校验。
- iOS 新增有界跨帧深度结构提取、粗中细 Top‑K 距离场匹配、状态滞回与小幅地图锚点修正。
- 新增用户触发的 ARFrame Vision 条码识别、同帧深度/MAD 测量、货架射线回退和货架侧面/offset/高度关联。
- 新增 constraint/state/tag observation/localized tag sidecar；weak/lost 不自动确认，最终价签由用户确认。
- HUD 显示结构匹配证据、耗时和扫码入口；PC inspect 提供有界审计汇总。
- 新增动态干扰/错误初始化回放、货架关联边界测试和性能基线。
- NFC 继续保持暂停；自由扫描和连续单库格式不变。

## 2026-07-24 — 阶段一

- 根据独立代码审查修正 ARKit 水平坐标/yaw 与地图/UI 约定，并增加方向金标测试。
- 校验器扩展为全 JSON/PNG 解析和跨文件一致性校验，补充损坏包负向测试。
- 道路边加入空间索引，iOS 使用附近候选并增加 in-flight 丢帧门控。
- iOS 地图缓存改为临时校验后原子替换；设备检查不再把未启动的 ARKit tracking 写成成功。
- 回放的旋转漂移现在同时影响 XY 轨迹并输出 yaw 误差。
- 明确一次扫描只绑定一个楼层；楼层内少量竖直位移忽略于二维先验定位、保留于原始三维数据；新增逐楼层预览。
- 新增 dependency-free XLSX 先验地图转换、校验和 PNG 渲染。
- 定义 version 1 地图包、统一米制 SE(2)、道路图和空间索引。
- Map Studio 新增先验地图异步导入、校验、统计和缩放预览。
- iOS 新增自由扫描/已有地图辅助扫描双模式和五步向导。
- 新增 ARKit 初始投影、道路软约束、候选/置信状态 HUD 和人工确认审计。
- 新增 localization trace、manual event 和 metadata/checkpoint 字段。
- 新增 synthetic/trajectory replay 及阶段一测试。
- 保留 `scanMode=continuous_streaming`，新增 `workflowMode`，确保旧连续单库流程兼容。
- NFC 仍保持暂停；未加入 LiDAR 自动匹配或价签扫码。
