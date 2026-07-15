# Supermarket Map Studio

Supermarket Map Studio 是 `Supermarket2DMap` 的本机可视化工作台。它在 macOS、Windows、Linux 上通过浏览器提供单设备合并、多设备合并、可选阶段校正、质量复核和动态彩色 2D/3D 预览。

## 依赖

- Python 3.9 或更高版本。
- 不需要 `pip install`、Node.js、Qt、Electron、Docker 或网络连接。
- 文件夹选择使用 Python 自带 Tk。大多数 macOS/Windows Python 默认带有它；部分 Linux 发行版需安装系统包 `python3-tk`。即使没有 Tk，也可在界面路径框中粘贴目录路径。

## 启动

macOS/Linux：

```bash
cd tools/SupermarketMapStudio
chmod +x start.sh
./start.sh
```

Windows：在资源管理器双击 `start.bat`，或在命令提示符执行：

```bat
tools\SupermarketMapStudio\start.bat
```

启动后默认浏览器会打开 `http://127.0.0.1:8765/`。服务只监听本机回环地址，扫描数据不会发送到网络。关闭运行启动命令的窗口即可退出。

## 使用流程

1. 从 iPhone 复制完整的 `SupermarketSession-*` 目录到 PC。确认其中包含每个 `segment_*/rtabmap_segment_*.db` 和 sidecar 文件。
2. 在 `单设备合并` 或 `多设备合并` 选择处理流程。单设备的直接合并和分阶段校正已经位于同一个面板中。
3. 选择会话目录后，工作台会自动在该会话内填入一个新的 `MapStudio-*` 输出子目录；原始 `segment_*` 不会被改动。也可手动改为其他新的空目录；多设备模式逐台添加会话，默认以第一台会话作为输出位置。
4. 需要人工校正时，用“添加阶段”输入分段范围（如 `1-3,5`）和 dx、dy、yaw 微调；不添加阶段时直接按会话内的 segment 处理。添加人工阶段后，相邻分段自动对齐会关闭，避免重复校正。
5. 多设备模式中可设置设备的平移/旋转初值；默认启用共同起点初始对齐。
6. 点击生成按钮，等待顶部状态显示“地图生成完成”。
7. 右侧默认显示 `2D 彩色俯视`，它从与 3D 相同的 RGB-D 三角表面取最高可见表面，保留实际商品、货架和地面的图像颜色；`2D 结构图` 保留占据、通行、冲突和轨迹语义；`3D 彩色模型` 可在 `旋转`、`平移` 两种拖动模式间切换，滚轮缩放，并可开关表面、点云和轨迹。在旋转模式下按住 Shift 拖动可临时平移。
8. 检查质量复核区域和成果文件；“打开输出目录”会用系统文件管理器打开地图包。

会话根目录中的 `segment_*` 会被自动发现并合并。macOS 在移动硬盘上创建的 `._*` 元数据文件会被忽略；数据库轨迹不可用时，工具会回退读取 `trajectory_samples.json/csv`。没有任何有效轨迹或结构点时任务会失败，不会把空地图标记为生成完成。

选择或粘贴会话目录后，工作台会扫描其中已有的 `MapStudio-*`、`Map2D-*` 和 `StageMap2D-*` 完整结果，自动加载最近一次有效的单设备结果。相同设置再次点击生成只继续显示该结果，不创建重复目录；修改参数或添加阶段校正后才会换用新的输出目录重新生成。

单设备入口会自动发现会话内的全部 `segment_*`。无阶段配置时直接合并，适合快速检查；存在阶段配置时会生成阶段清单并应用 `dx`、`dy`、`yaw` 校正，适合长距离扫描后的累积误差修正和人工复核。

## 输出

每次任务输出一个可追溯地图包，重点文件包括：

- `preview.png`、`occupancy_grid.png`：二维结果。
- `preview_3d.json`：抽样关键帧的三维顶点、三角面、图像 UV、点云、轨迹和结构点。
- `preview_frames/`：与三维表面对应的 RGB 关键帧；浏览器在本地加载并把真实颜色映射到三角面。
- `quality_report.json`、`review_items.json`：质量检查和人工复核项。
- `trajectory.geojson`、`price_tags.geojson`、`vector_map.geojson`：可导入 QGIS 的矢量数据。
- `stage_manifest.json` 或 `multi_device_manifest.json`：校正与设备/分段映射。

三维视图会联合数据库中的节点位姿、相机标定、LiDAR 深度 PNG 和 RGB 图像，重建带真实图像颜色的局部三角表面并使用 WebGL 显示；相邻深度跳变过大时不会跨越生成三角形，以减少墙边和货架边缘的拉丝。二维占据图也会投影这些 RGB-D 表面中位于地面以上约 0.25 至 2.8 米的结构，不再只有轨迹覆盖。

`3D 表面质量` 有三档：`快速` 最多 96 帧/10 万点，适合检查；`详细` 最多 192 帧/40 万点，是默认选项；`最高` 最多 320 帧/80 万点，适合在内存充足的 PC 上生成最终复核结果。帧会在整个会话中均匀抽取，每帧还会按总点数预算自动增大像素步长，因此不会把全部原始深度像素一次送入浏览器。真实数据库和原始图片不会被修改。

当前彩色结果是关键帧级、顶点着色的 RGB-D 表面集合，视觉细节已接近手机客户端的彩色点云/表面模式，但它不是经过全局网格融合、重纹理和孔洞修复的封闭模型，也暂不导出 OBJ/PLY/GLB。需要可交付的无毛刺高质量网格时，仍应增加 RTAB-Map C++ 图优化与 mesh 后处理导出阶段。

## 测试

```bash
python3 -m unittest discover -s tools/SupermarketMapStudio/tests -v
```

测试会在临时目录创建最小 RTAB-Map SQLite 会话，不修改真实扫描数据。
