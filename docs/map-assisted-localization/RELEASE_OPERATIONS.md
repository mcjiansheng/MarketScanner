# Map Studio 发布、启动、恢复与数据生命周期

> 文档状态：**当前有效**。最后核对日期：2026-07-28。

## 安全启动边界

Map Studio 只允许绑定 `127.0.0.1`。每次进程启动生成新的 256-bit 级随机 session token，token 只放在浏览器启动 URL fragment 中；页面读取后立即从地址栏移除并保存到当前 tab 的 `sessionStorage`，服务端不写 journal、诊断包或日志。所有 POST（包括路径选择和只读 inspect）都要求 `X-MarketScanner-Session-Token`；有 `Origin` 时必须精确匹配当前 `http://127.0.0.1:<port>`，无 Origin 只用于持有 token 的受控 launcher/CLI。静态资源和 API 返回 CSP、frame deny、no-referrer、nosniff。

`GET /api/about` 显示产品版本、source Git SHA、Python/platform 和启动检查；`GET /api/recovery` 列出 interrupted jobs 与安全恢复步骤。浏览器“版本与恢复”直接显示这些信息。

## 启动自检

```bash
python3 tools/SupermarketMapStudio/server.py --version
python3 tools/SupermarketMapStudio/server.py --selfcheck
```

生产启动器会先检查 Python >= 3.10、至少 1 GiB 状态盘空间、`rtabmap-reprocess`、完整相对 SE(2) helper 和 operator package integrity；两个 native 工具会实际执行 `--version` 并核对 package/source SHA，而不是只检查文件存在。任一关键项缺失都退出，不以有限功能模式伪装生产可用。损坏/旧格式 job journal 会 fail closed、不加载也不清理其路径，但作为可恢复告警允许服务启动，供操作者从“版本与恢复”查看并先导出诊断。

- macOS：`tools/SupermarketMapStudio/launch_macos.command`
- Windows PowerShell：`tools/SupermarketMapStudio/launch_windows.ps1`

## Hash-bound operator archive

先用 `release_manifest.py` 为两个 native 二进制生成对应平台 release manifest，再生成不可覆盖的操作员 ZIP：

```bash
python3 tools/SupermarketMapStudio/package_release.py \
  --platform macos \
  --output /new/path/MarketScanner-MapStudio-macos.zip \
  --release-manifest /path/release-manifest.json \
  --reprocess /path/rtabmap-reprocess \
  --factor-helper /path/rtabmap-prior-map-factor-graph
```

Windows 使用 `--platform windows` 和 `.exe` 二进制。打包器复核 release manifest body SHA、platform、当前 clean source HEAD、两个二进制 `--version` 中的 source SHA 及二进制大小/SHA，并为全部 Python/web/launcher/native 文件生成 `MarketScannerMapStudioOperatorPackage` manifest。目标 ZIP 已存在、source tree 有改动、manifest 被改写或二进制发生同尺寸替换时均失败；解压后 selfcheck 会逐文件重算 package manifest。

本仓库已完成打包器与模拟二进制合同测试，但尚未在干净 Windows/macOS 终端执行解压、launcher、自检、处理、升级和卸载 smoke，因此 P7 仍不能声明平台安装验收通过。

## 诊断、恢复与日志

浏览器“导出诊断”生成唯一 ZIP，包含版本/启动检查、bounded job 摘要和 journal/runtime logs；单文件上限 16 MiB、总日志上限 128 MiB，symlink 跳过，session token 永不进入包。输出返回 archive SHA-256，已存在路径不会复用。

恢复规则：

- restart 后未完成任务只标记 `interrupted`，不猜测续跑；
- 重试前核对原始输入 identity，并使用新的 staging/output；
- 旧 current/published 不因失败重试改变；
- corrupted journal 不驱动未知路径清理；
- cleanup/review/publish 继续要求既有确认、版本 revision 和 CAS，不因恢复 UI 放宽。

## 备份、保留、升级与卸载

- raw session、prior-map package、localized immutable version、field evidence 和 release/build manifest 各自作为独立 hash-bound package 备份；
- raw session 至少保留到 PC source 校验、localized current 生成、第二份独立验证副本和操作者显式清理全部完成；
- 升级前导出诊断并备份 job state，安装新版本到新目录；旧目录在 clean-install smoke 与一次真实输入复核完成前保留；
- 卸载程序/删除工具目录不得自动删除 raw session、结果、evidence、job state 或外部副本；数据清理由单独、显式、可审计流程完成；
- NFC 入口继续关闭，发布包不得把暂停功能重新接入扫描入口。
