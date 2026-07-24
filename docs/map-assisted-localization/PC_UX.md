# PC 先验地图工作台交互

> 文档状态：**当前有效（阶段一）**。最后核对日期：2026-07-24。

Map Studio 新增“导入/管理先验地图”页签，不改变单设备和多设备扫描处理入口。

## 导入流程

1. 选择含 `Element Info` 的 XLSX。
2. 可选输入普通业务地图名称。
3. 选择空输出目录。
4. 后台显示读取、坐标/几何转换、schema 校验和预览进度。
5. 完成后显示可缩放 2D 预览、地图 ID、源 SHA-256、楼层、范围、元素统计和 warning。

错误信息说明：

- 发生了什么；
- 源 Excel 未修改；
- 用户应在验证报告中查看哪类问题或重新选择什么文件。

页面明确显示：“阶段一定位为初始位置投影 + 道路软约束；尚未启用 LiDAR 自动地图匹配。”避免把未实现能力呈现为完成。

## API

```text
POST /api/prior-map/convert
  { xlsx, output, name? }

POST /api/prior-map/inspect
  { package }

GET /api/jobs/<id>
GET /api/jobs/<id>/artifact/<allowlisted-name>
```

转换复用现有有界后台 Job 状态、日志和进度模型。地图包成果仅通过 allowlist 读取；任意路径不能作为 artifact 访问。

## 未实现

阶段一不包含已有地图辅助扫描的 PC 轨迹/价签复核向导。该界面需要阶段二产生真实地图匹配约束和价签观测后再实现，避免空壳 UI 暗示可用。
