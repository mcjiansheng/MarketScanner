# Map Studio 持久任务与中断恢复

> 文档状态：**当前有效**。最后核对日期：2026-07-28。

## 目标与边界

Map Studio 把任务状态写入本机 journal，使浏览器刷新和服务进程重启后仍能看到任务历史、进度、错误及原生重处理日志。原始扫描数据库仍只读；任何未完成的 staging 都不会被当成已发布成果。

P3 不实现跨进程“继续执行”。服务重启时，先前处于 `queued`、`running` 或 `cancelling` 的任务统一转换为 `interrupted`，保留进度和日志，并要求操作者选择新的空输出目录重新启动。这样避免在无法证明子进程和临时文件一致性的情况下猜测恢复。

## 存储协议

- 默认目录：系统临时目录下按本机用户 home 摘要隔离的 `marketscanner-mapstudio-*/jobs`。
- 可用 `MARKETSCANNER_JOB_STATE_DIR` 指定受控持久目录。
- 每个任务一个 `0600` JSON journal，格式为 `MarketScannerMapStudioJob` version 1。
- 更新流程是同目录唯一临时文件、写入、flush、文件 `fsync`、原子 replace；POSIX 平台随后同步目录。
- journal 只接受 12 位十六进制任务 ID、绝对输出路径、有限时间戳、已知状态和有界进度。损坏或未知 schema 会在 `/api/health` 的 `startup_errors` 中失败关闭，不根据其中的路径删除任何文件。
- 默认保留最近 200 个终态任务，可配置范围为 20–1000。超出保留数时同时删除该任务 journal 和严格按任务 ID 命名的原生运行日志。

## 状态机

```text
queued -> running -> complete
                  -> failed
                  -> cancelling -> cancelled

queued/running/cancelling + service restart -> interrupted
```

`complete` 是唯一可提供完整成果 artifact 的状态。`failed`、`cancelled` 和 `interrupted` 都不会改变既有已发布版本指针。

## 取消与子进程

`POST /api/jobs/<id>/cancel` 设置持久的取消意图并触发进程内事件。PC 重处理循环检测事件后先向 `rtabmap-reprocess` 发送 terminate，5 秒内不退出再 kill，并等待子进程回收。partial 输出被删除，源数据库重新比对保持不变。快速复用和闭环发现两次 pass 的原始日志分别保存为严格命名的 `*-fast.log`、`*-discovery.log`，可从任务 API 的 `runtime_logs` 下载。

纯 Python 生成阶段只能在进度检查点响应取消；因此 UI 显示“正在取消”，直到当前有界步骤返回。服务重启不会基于 journal 路径自动清理输出目录，避免 TOCTOU 或损坏 journal 导致越界删除。

## API 与浏览器恢复

```text
GET  /api/health
GET  /api/jobs
GET  /api/jobs/<id>
GET  /api/jobs/<id>/runtime-log/<exact-log-name>
POST /api/jobs/<id>/cancel
```

页面打开时读取最近任务：活动任务重新连接轮询，完成任务恢复成果视图，中断任务显示必须重新运行。任务 journal 是本机运行证据，不属于可移植地图成果包。

## 自动验证

- 活动任务重启后变为 `interrupted`，进度和历史保留；
- 取消意图落盘并唤醒 worker；
- 实际长运行子进程被终止，原始 DB 字节不变，partial 输出不存在，原始日志留存；
- 损坏 journal 失败关闭，伪造输出路径中的文件不被删除；
- Map Studio 全量回归覆盖任务 API、成果访问边界和原有处理链。

这些测试不等价于断电、Windows handle、安装包或现场资格测试，后者仍由 P4–P8 单独验收。
