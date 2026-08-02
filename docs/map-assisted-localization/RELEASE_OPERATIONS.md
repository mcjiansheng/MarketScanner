# Map Studio 发布、启动、恢复与数据生命周期

> 文档状态：**当前有效**。最后核对日期：2026-08-02。

## 安全启动边界

Map Studio 只允许绑定 `127.0.0.1`。每次进程启动生成新的 256-bit 级随机 session token，token 只放在浏览器启动 URL fragment 中；页面读取并立即移除 fragment，再通过 `POST /api/session/bootstrap` 换取 30 分钟 `HttpOnly; SameSite=Strict` cookie。页面保持打开时每 5 分钟通过同源、已有 cookie 认证的 `POST /api/session/refresh` 续期，并在页面重新可见或获得焦点时补充续期；refresh 不能使用匿名请求或 token-header CLI 通道创建浏览器会话，前端也不持久化启动 token。服务进程重启后旧 cookie 仍会失效，启动器必须用新 URL fragment 打开页面。除匿名静态文件和不含路径/版本的最小 health 外，敏感 GET、artifact/runtime log 与 POST 都要求有效 cookie（受控 CLI 可直接提供 token header）。所有有 `Origin` 的 POST 必须精确匹配当前 `http://127.0.0.1:<port>`。服务端不把 token 写入 journal、诊断包或日志；响应继续包含 CSP、frame deny、no-referrer、nosniff。

`GET /api/about` 显示产品版本、source Git SHA、Python/platform 和启动检查；诊断必须使用 server 的真实 `runtime_mode`，production UI 不得展示 development 默认检查。`GET /api/recovery` 列出 interrupted jobs 与安全恢复步骤。浏览器“版本与恢复”直接显示这些信息。

## 启动自检

```bash
python3 tools/SupermarketMapStudio/server.py --version
python3 tools/SupermarketMapStudio/server.py --selfcheck
python3 tools/SupermarketMapStudio/server.py --selfcheck --mode production
python3 tools/SupermarketMapStudio/server.py --mode production
```

严格 production mode 会检查 Python >= 3.10、至少 1 GiB 状态盘空间、`rtabmap-reprocess`、完整相对 SE(2) helper、package/release manifest、合法 source SHA、native SHA 一致、依赖/质量 policy 绑定且质量策略为 frozen、平台 app-data state 目录可用；两个 native 工具会实际执行 `--version`。任一关键项缺失都退出，不以有限功能模式伪装生产可用。development source checkout 会明确显示 `DEVELOPMENT / NOT QUALIFIED FOR PRODUCTION`。损坏/旧格式 job journal 会 fail closed、不加载也不清理其路径，但作为可恢复告警允许服务启动，供操作者从“版本与恢复”查看并先导出诊断。

发布动作只能由 `runtime_mode=production` 的 server 执行；development runtime 即使 release、Field Evidence、full factor graph 和 frozen policy 全部有效也固定返回 403，CLI/API 不能绕过。服务端在调用 `store.publish_current()` 前必须重新执行 `startup_diagnostics("production")`，只有 `production_qualified=true` 且 `can_start=true` 才继续；随后只从安装包根目录稳定读取 release manifest，并核对 package manifest 的 exact release SHA/Git SHA。production 忽略 `MARKETSCANNER_RELEASE_MANIFEST` 外部覆盖，失败路径不改变 current/published pointer。

operator package 的 manifest/release/quality JSON 和逐文件 hash 都通过保持打开的主 descriptor 读取；读取前后用同类 path descriptor 绑定文件身份，路径元数据只与路径元数据比较。Windows 使用 binary descriptor 保留 CRLF 等磁盘原始字节；打开句柄阻止替换、同尺寸替换、临时替换后恢复、部分读取或身份变化均失败关闭。

发布动作必须导入 `MarketScannerFieldQualificationEvidence` v3；UI checkbox 只表示操作者确认。evidence 自包含 exact Field Plan、release/quality contract、每次 run 的 manifest-bound trajectory source、控制点 CSV 和 Device Evidence；inspect/store 从这些字节重新派生全部质量数值、阈值和身份。store 在写锁内稳定复读 evidence 并核对操作者选择时的 SHA，将 exact accepted bytes 复制为 published version 的 `field_evidence.json`，同时生成 `qualification_manifest.json`。两个文件进入 `MarketScannerLocalizedVersionManifest` v4 的逐文件 hash tree，published/revoked resolve 会重新验证；外部 evidence 后续删除或修改不影响审计。发布记录继续分别保存 `review_evidence_sha256`、field body/file SHA、release/prior-map/quality-policy identity、candidate version/revision、actor/reason/UTC。

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

Windows 使用 `--platform windows` 和 `.exe` 二进制。打包器复核 release manifest body SHA、platform、当前 clean source HEAD、两个二进制 `--version` 中的 source SHA 及二进制大小/SHA，并为全部 Python/web/launcher/native 文件生成 `MarketScannerMapStudioOperatorPackage` manifest。目标 ZIP 已存在、source tree 有改动、manifest 被改写或二进制发生同尺寸替换时均失败；解压后 selfcheck 会逐文件重算 package manifest。package/release/quality 三个 JSON 均从一次 `O_NOFOLLOW` descriptor 稳定读取的 exact bytes 同时完成解析与 SHA，symlink、hard link、同尺寸 path replacement 和读中变化全部失败关闭。

本仓库已完成打包器与模拟二进制合同测试。2026-07-28 在当前 macOS 主机为代码提交 `283c2b62672f0be4400f13848f67b50cfaea5ca7` 重新执行 150-step release build，两个 native 工具均报告该 SHA；生成并解压 operator ZIP 后，launcher 的 package integrity、native `--version` 和关键 selfcheck 通过。该临时 ZIP 为 371,688 bytes，SHA-256 `073a5771c0bfe94368e3d05438d950e20d4c8d82ca070ad5b9278a2c78d93927`。这仍是已有 Homebrew/runtime 的同机 smoke；尚未在干净 Windows/macOS 终端执行依赖隔离、实际处理、升级和卸载，因此 P7 不能声明平台安装验收完成。

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
