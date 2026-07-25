# 阶段三实现与验证报告

> 文档状态：**当前有效**。最后核对日期：2026-07-25。
>
> 结论限定：阶段三代码与自动验证已实现；正式 LiDAR iPhone 干跑、超市现场验收和独立复审尚未执行，因此本报告不代表生产批准。

## 实现范围

- Map Studio 的“先验地图会话优化”先生成只读源库的优化副本，再读取 RTAB‑Map 全局优化位姿；源数据库处理前后以 SHA‑256 验证不变。
- 将 RTAB‑Map 相对轨迹对齐到已绑定的单楼层地图坐标，使用带角度环绕、Huber IRLS、平滑相对轨迹和固定初始 gauge 的带状 SE(2) 修正器。
- 输入在线结构约束、人工定位事件、人工锚点，以及只在既有轨迹已接近通道时生效的低权重道路区域/方向软约束；远端错误约束通过硬门限拒绝并进入审计。
- 根据离线轨迹修正价签坐标，重新关联稳定货架面 `A/B` 或柜台边 `E##`，输出 JSON、CSV、GeoJSON 和货架索引。
- 输出定位轨迹、原始/接受/拒绝约束、质量报告、复核列表、处理/来源清单与有界审计日志。
- 人工编辑日志与地图包 SHA‑256、源会话 SHA‑256 绑定，支持锚点、禁用约束、通道区间、价签编辑/批准、撤销和重做；每次编辑从原始派生数据确定性重放。
- 当前只考虑单一楼层。楼层内部少量竖直位移保留在 RTAB‑Map 原始三维数据中，不参与二维先验地图 SE(2) 优化。

## 安全边界

- 该求解器是“RTAB‑Map 优化轨迹之上的稳健带状 SE(2) 派生修正”，不是通用因子图实现。
- 原始扫描数据库不做就地优化；处理产物只写入新输出目录。
- `automatic_publish_allowed=false` 时结果只能进入人工复核，不得冒充自动发布成功。
- 联动复核画布显示先验结构、在线/RTAB‑Map/离线三条轨迹和价签，支持按状态/货架筛选并从价签或问题带入编辑对象；对象 ID/JSON 保留为精确审计编辑，地图直接拖拽锚点仍属于可用性增强项。

## 自动验证

验证命令：

```bash
python3 -m unittest discover -s tools/PriorMap/tests -v
python3 -m unittest discover -s tools/SupermarketMapStudio/tests -v
python3 -m py_compile tools/PriorMap/*.py tools/SupermarketMapStudio/*.py
python3 tools/PriorMap/benchmark_stage3.py \
  --nodes 2000 --max-seconds 15 --max-peak-mib 64
node --check tools/SupermarketMapStudio/web/app.js
xcodebuild -project app/ios/RTABMapApp.xcodeproj \
  -scheme RTABMapApp -configuration Debug \
  -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build
git diff --check
```

自动测试覆盖地图包完整性负例、L 形道路弧长排序、深度证据、快照时效、时序门复位、稳定结构面、道路软约束、错误盆地拒绝、源库不可变、确定性导出和人工编辑分支。

本次回归结果：PriorMap 26 项通过，Map Studio 55 项通过，Python/JavaScript 语法和 `git diff --check` 通过，iPhone arm64 无签名构建 `BUILD SUCCEEDED`。Xcode 仍输出仓库既有的旧 API/脚本阶段 warning，本次没有新增编译错误。

本机 2,000 节点/20 约束基准（Python `tracemalloc` 开启）耗时 3.426 秒、峰值 Python 跟踪内存 0.562 MiB，低于 15 秒/64 MiB 门限。该数字不包含 RTAB‑Map、2D/3D 生成和操作系统原生库内存，也不能替代真实大库与真机性能测试。

## 尚待完成

- 支持 LiDAR 的真实 iPhone 完整采集、扫码、弱纹理/动态行人、结束落盘和外部复制干跑；
- 正式超市单楼层现场精度与性能验收；
- 本轮阶段一/二整改和阶段三实现的独立代码复审；
- 地图直接拖拽锚点和更丰富的批量编辑等非专业用户可用性增强。
