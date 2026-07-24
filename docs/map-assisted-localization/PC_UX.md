# PC 先验地图工作台交互

> 文档状态：**当前有效（阶段二）**。最后核对日期：2026-07-24。

Map Studio 新增“导入/管理先验地图”页签，不改变单设备和多设备扫描处理入口。

## 导入流程

1. 选择含 `Element Info` 的 XLSX。
2. 可选输入普通业务地图名称。
3. 选择空输出目录。
4. 后台显示读取、坐标/几何转换、schema 校验和预览进度。
5. 完成后显示可缩放 2D 预览、地图 ID、源 SHA-256、楼层、范围、元素统计和 warning。地图包为每个楼层生成独立预览；手机一次扫描只选择其中一层。

错误信息说明：

- 发生了什么；
- 源 Excel 未修改；
- 用户应在验证报告中查看哪类问题或重新选择什么文件。

地图包导入同时生成并校验多分辨率结构距离场。已有地图扫描会话的 inspect API 有界汇总结构约束接受数、状态变化、价签观测、最终确认价签、待复核数和 malformed 记录，不读取或改写原始数据库。

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

## 当前未实现

阶段三 PC 轨迹/约束/价签地图人工编辑与导出界面尚未实现。阶段二只提供会话审计汇总与原始 sidecar，不能把 inspect 统计表述为完整复核工作台。
