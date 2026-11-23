---
name: sweep-clean
description: Clean a Mac through the sweep MCP tools (Sweep's scan engine) with a visible, reversible flow — scan, show a picture, build a plan with a digest, and only delete after the user approves. Use when the user says "磁盘满了", "清理电脑/Mac", "释放空间", "清理缓存", "清理垃圾", "看看什么占空间", "清一下 node_modules/.venv", "找重复文件/大文件", or in English "disk full", "free up space", "clean my mac", "clear caches", "what is taking space". Also use when the user asks to scan, plan, or undo a sweep cleanup, or mentions sweep / Sweep / sweep-mcp.
---

# sweep 清理

把清理做成**看得见、可撤销**的流程：扫描 → 出图 → 计划（带 digest）→ 用户同意 → 执行 → 结果图 → 可撤销。

工具来自 `sweep` MCP（12 个），底层是 [Sweep](https://github.com/iliyami/Sweep) 的 `MacCleanKit`。

## 铁律

1. **不确认不执行**。`apply_clean` 之前必须有用户明确同意；`plan_clean` 不删除任何东西。
2. **只认 id**。候选 id 必须来自 `scan_*` 返回的 `snapshotPath`；不要拼路径、不要猜 id、不要手写 `--ids`。
3. **用户文件逐项确认**。大文件、旧文件、重复文件属于用户自己的内容，必须逐条列出并由用户勾选，永不批量删。
4. **受保护路径不争取**。`~/Documents`、`~/Desktop`、`~/Pictures`、`.git`、`.ssh`、钥匙串会被代码拒绝；如实报告即可，不要绕过。
5. **删除前后各出一张图**（见下）。

## 工作流

### 0. 先看模式

```
cleanup_mode                     # readonly / confirm / auto
```

- `readonly`：只扫描、出图，明确告诉用户执行被禁用；
- `confirm`（默认）：必须带 digest；
- `auto`：仅白名单缓存类可无人值守，其它类别仍需确认。

### 1. 扫描（异步，别用同步工具）

```
scan_start(module: "system-junk" | "project-junk" | "large-files" | "old-files" | "duplicates", …)
  → jobId
scan_status(job_id)              # 每 3–5 秒轮询，20–60 秒完成
```

系统垃圾和项目垃圾**必须**走 `scan_start`：同步接口会撞客户端超时。返回里的 `snapshotPath` 后面要用。

客户端不支持异步时，退回 CLI（同一套逻辑）：

```bash
sweep scan system-junk --json --limit 5
```

### 2. 出图

每种能力都有对应视图，别用文字描述代替图：

| 场景 | 调用 |
|---|---|
| 磁盘占用 | `render_chart(view: "disk")` |
| 自主度 / 权限 / helper | `render_chart(view: "status")` |
| 清理记录 | `render_chart(view: "ops")` |
| 系统垃圾 / 项目垃圾 | `render_chart(snapshot: S, top: 8)` |
| 大文件 / 旧文件 / 重复文件 | `render_chart(snapshot: S, view: "entries")` |
| 计划确认 | `render_chart(plan: P)` |
| 执行结果 | `render_chart(op: O)` |

返回 image 内容块（PNG）。已验证 DSH 会**直接在对话里渲染工具返回的图片**，所以不要再用 `![]()` 重复贴一次（会显示两遍）。只有当客户端明显没渲染时，才用返回路径补一张 markdown 图片。

开扫前先贴磁盘图，删除后贴结果图，收尾贴审计图，这样用户全程有画面。

### 3. 挑候选

默认只选**可重建**类别：包管理器缓存、用户/系统缓存、日志、Xcode/IDE/AI 缓存、旧安装包、残留下载。

- 说明每类大概是什么、删了会怎样（会不会重新下载、要不要重装依赖）；
- 大文件/旧文件/重复文件：先列清单（路径 + 大小），让用户勾选；
- 图片里的“未使用磁盘映像”常常是用户自己下载的安装包，**要单独问**。

按体积挑，避免逐个操作上万个碎文件：`sweep plan --min-bytes 5 --categories …` 或先取 `top` 里的 id。

### 4. 计划

```
plan_clean(snapshot: "<S>", ids: [...])
  → planId, digest, count, totalBytes
render_chart(plan: "<planId>")
```

计划图里已经包含：每一项的路径与大小、总释放量、digest 前 16 位。

### 5. 确认

图 + 一行摘要 + digest。示例：

> 计划 `56239a03`：13 项 / 3.89 GB，全部是可重建缓存。
> 要执行吗？执行后进废纸篓，一条 `restore_clean` 可整体还原。

**等用户回复**。用户改变选择就重新 `plan_clean`（digest 会变），不要拿旧 digest 硬执行。

### 6. 执行

```
apply_clean(plan_id: "<P>", digest: "<D>")
```

- 逐项失败是正常的（权限不足、路径已变）；如实报告 `failures`，不要重试到成功为止；
- drift（文件大小变了）说明计划作废，重新扫描。

### 7. 结果图

```
render_chart(op: "<operationId>")
```

图上带 ✓/✗ 与撤销命令。再附一行：移动了多少项、多少 GB、操作 id。

### 8. 撤销

```
restore_clean(operation_id: "<O>")
```

在废纸篓被清空之前有效。

### 9. 收尾

必须说清：**移入废纸篓不等于释放空间**，清空废纸篓才真正回收，而清空后无法撤销。不要替用户清空废纸篓。

## 失败与边界

| 现象 | 处理 |
|---|---|
| 扫描超时 | 改用 `scan_start` → `scan_status`；仍失败走 CLI |
| 结果偏小、`deniedPaths` 非空 | 说明缺少「完全磁盘访问权限」，不是“没有垃圾”；给出 `sweep helper-install` + 系统设置路径。**判据只有 `deniedPaths` 是否为空**，不要用 `sweep fda` 的三行 DENY 下结论（那是调用者进程的权限） |
| 授权后仍 DENY | 检查 helper 的 app 是否被签名（`codesign -dv` 应显示 `Identifier=com.sweep.helper`）；未签名时系统设置里的条目不会生效 |
| 图片不渲染 | 先用路径补一张 `![]()`；仍不行再退回表格 + 路径文字 |
| 工具返回 `Protected path` | 正常拦截，跳过该项并说明 |
| `Category not allowed in auto mode` | 该类别不允许无人值守，回到确认流程 |
| 用户想删 `~/Documents` 里的东西 | 拒绝，并建议用户自己确认后手动处理 |

## 报告格式

```markdown
扫描：系统垃圾 9.82 GB / 118,709 项（同图）
![…](路径)

计划 56239a03：13 项 / 3.89 GB
![…](路径)

（等待确认）
```

不要写成大段文字总结；**图 + 一行数字**就是报告。

## 不要做

- 不因为“用户说要清理”就跳过计划与确认；
- 不把 `du`/`rm` 当成 sweep 的替代（要恢复能力就走 `plan_clean → apply_clean`）；
- 不删 `.git`、不删 Gradle 发行包里的单个 jar 这类会破坏完整性的东西；
- 不在 `auto` 模式下碰用户文件；
- 不承诺“永久删除”——本工具只进废纸篓。
