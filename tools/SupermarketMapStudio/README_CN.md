# Supermarket Map Studio

Supermarket Map Studio 是 `Supermarket2DMap` 的本机可视化工作台。它在 macOS、Windows、Linux 上通过浏览器提供单设备阶段建图、多设备合并、基础 2D 地图、质量复核和动态 2D/3D 预览。

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
2. 在 `2D 地图`、`单设备阶段` 或 `多设备合并` 选择处理模式。
3. 用“选择文件夹”选取会话目录和一个新的空输出目录；多设备模式逐台添加会话。
4. 单设备阶段模式中可用“添加阶段”输入分段范围（如 `1-3,5`）和 dx、dy、yaw 微调；不添加阶段时按每个分段自动处理。
5. 多设备模式中可设置设备的平移/旋转初值；默认启用共同起点初始对齐。
6. 点击生成按钮，等待顶部状态显示“地图生成完成”。
7. 在右侧切换 `2D` 与 `3D`：2D 视图可拖拽和滚轮缩放；3D 视图可拖拽旋转、滚轮缩放。
8. 检查质量复核区域和成果文件；“打开输出目录”会用系统文件管理器打开地图包。

## 输出

每次任务输出一个可追溯地图包，重点文件包括：

- `preview.png`、`occupancy_grid.png`：二维结果。
- `preview_3d.json`：动态三维预览数据。
- `quality_report.json`、`review_items.json`：质量检查和人工复核项。
- `trajectory.geojson`、`price_tags.geojson`、`vector_map.geojson`：可导入 QGIS 的矢量数据。
- `stage_manifest.json` 或 `multi_device_manifest.json`：校正与设备/分段映射。

三维视图基于轨迹、价签和可选 `points.csv` 结构点；它用于检查覆盖、对齐和高度趋势，并非完整纹理 mesh。

## 测试

```bash
python3 -m unittest discover -s tools/SupermarketMapStudio/tests -v
```

测试会在临时目录创建最小 RTAB-Map SQLite 会话，不修改真实扫描数据。
