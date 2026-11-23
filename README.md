# sweep

把第三方开源扫描引擎（`MacCleanKit`，BSD-3）包装成一个**结构化、可撤销、可被 agent 调用**的本地工具：CLI + MCP server + DSH bundle。引擎来源与许可声明见 [NOTICE](NOTICE.md)。

当前版本 **0.2.0**（M2）：扫描、清理、撤销、三种自主度、四类客户端接入。

## 安装

```bash
./install.sh                       # 二进制 + DSH bundle + skill
SWEEP_PREFIX=/usr/local/bin ./install.sh
SWEEP_SKIP_HELPER=1 ./install.sh  # 不装 FDA helper
```

## 分发给别人

```bash
./scripts/package.sh
# → dist/sweep-0.2.0-macos-universal.tar.gz (2.5 MB，x86_64 + arm64) + .sha256
```

对方拿到后：

```bash
tar xzf sweep-0.2.0-macos-universal.tar.gz
cd sweep-0.2.0-macos-universal
./install.sh
```

`install.sh` 会做四件事：装二进制到 `~/.local/bin`、把 DSH bundle 生成到 `~/.local/share/sweep/dsh-bundle`（`cordis.patch.yml` 里的命令路径按实际安装位置写入，不写死）、把 skill 装到 `~/.agents/skills/sweep-clean`、最后可选安装 FDA helper。

### 三个必踩的坑（已在脚本里修掉）

1. **复制二进制必须用 `ditto`**。`cp` 会破坏 linker-signed 的 ad-hoc 签名，macOS 26 上直接 `Killed: 9`（日志：`Unrecoverable CT signature issue`）。
2. **helper 的 `.app` 必须签名**。不签名的 bundle 向 TCC 呈现的是内层二进制的身份，你在系统设置里加的条目永远不生效。
3. **ad-hoc 签名绑二进制哈希**。helper 升级会让授权静默失效，所以 `helper-install` 默认冻结已装二进制，升级要 `--force` 并重新授权。

> `install.sh` 用 `ditto` 而不是 `cp`：macOS 26 上 `cp` 复制 linker-signed 的 ad-hoc 二进制会破坏签名，AMFI 在 exec 时直接 `Killed: 9`（日志：`Unrecoverable CT signature issue`）。

## 能力

| 工具 / 命令 | 说明 | 会删东西吗 |
|---|---|---|
| `disk_report` / `sweep disk` | 数据卷总量、已用、可用 | 否 |
| `scan_start` + `scan_status` | **异步**扫系统垃圾（21 类）/ 项目垃圾 / 大文件 / 旧文件 / 重复文件；慢模块（系统垃圾 20–60s）不会触发客户端超时 | 否 |
| `scan_large_files` | 最大的用户文件（快，同步） | 否 |
| `scan_old_files` | 指定天数未修改的文件（同步） | 否 |
| `scan_duplicates` | 字节级相同副本（体积 → 部分哈希 → 全量 SHA-256 → 硬链接去重） | 否 |
| `plan_clean` | 用快照 + 已批准的 id 生成计划与 digest | 否 |
| `apply_clean` | digest 匹配后移入废纸篓 | **是**（可撤销） |
| `restore_clean` | 按操作记录放回原处 | 否（只还原） |
| `list_operations` | 最近的操作 | 否 |
| `cleanup_mode` | 读/改自主度 | 否 |
| `render_chart` / `sweep chart` | 把扫描或计划渲染成 PNG 并作为 image 内容块返回 | 否 |

## 界面：用图片，不用 HTML

客户端没有 UI 是核心痛点，但**不能靠 HTML**：对话里的 HTML 不会被渲染，iframe 拿不到主题与 locale。

图片是跨客户端唯一可靠的富内容形式——DSH / Codex / Cursor 只要支持 MCP 的 image 内容块就能显示。**DSH 已实测：工具返回的图片直接渲染在对话里**，不需要生成 HTML 文件、也不用手动贴路径。

每一种能力都有对应视图：

| 视图 | 命令 | MCP | 图上内容 |
|---|---|---|---|
| 磁盘 | `chart --disk` | `render_chart {view:"disk"}` | 可用空间、占用条（>90% 变红） |
| 状态 | `chart --status` | `{view:"status"}` | 自主度、完全磁盘访问、helper |
| 审计 | `chart --ops` | `{view:"ops"}` | 最近 10 次操作、撤销命令 |
| 扫描汇总 | `chart --snapshot S` | `{snapshot:S}` | 类别条形图 + 总可清理量 |
| 文件清单 | `chart --snapshot S --list` | `{snapshot:S, view:"entries"}` | 大文件/旧文件/重复文件逐条路径 |
| 计划 | `chart --plan P` | `{plan:P}` | 待清理清单 + digest |
| 结果 | `chart --op O` | `{op:O}` | ✓/✗ 状态 + 撤销 id |

文件类模块（`large-files` / `old-files` / `duplicates`）默认出清单而不是分类图。

两个细节：

- **图片自带背景**：PNG 不知道客户端是深色还是浅色，透明底 + 深色字在深色主题下会消失。所以统一画成深色卡片 + 浅色文字，两种主题都可读；
- **计划图带 digest**：确认动作和具体的路径/大小绑定在同一张图上，用户看到什么就批准什么。

> `experiments/dsh-ui-panel/` 是一次尝试过的 DSH 客户端面板（React + 主题令牌），因为只对 DSH 生效、跨客户端不可用而放弃，保留作参考。

## 两段式删除

```bash
sweep scan system-junk              # 输出里带 snapshotPath
sweep plan --snapshot <S> --ids <id1,id2>
#   → 计划 + digest，给用户看
sweep apply --plan <P> --digest <D> # 移入废纸篓
sweep restore --op <O>              # 撤销
sweep ops                           # 历史
```

安全约束（代码强制，不靠提示词）：

1. **只认 id**：`plan` 的候选必须来自快照，传路径无效 —— 文件名里的「指令」无法变成删除目标。
2. **digest 校验**：`apply` 必须回传计划摘要；计划文件被改、或文件大小在批准后变化（drift）都会拒绝。
3. **废纸篓 + 撤销**：删除即移入废纸篓，`restore` 原路放回，原位置已被占用则跳过并报告。
4. **受保护路径**：`~/Documents`、`~/Desktop`、`~/Pictures`、`.git`、`.ssh`、钥匙串等硬拒。
5. **预算**：单次 `maxBytes` / `maxItems` 超限直接拒绝。
6. **审计**：`~/.sweep/operations.jsonl`（600）逐项记录路径、字节、废纸篓位置、成功/失败原因。

## 三种自主度

`sweep mode` / MCP `cleanup_mode`，存在 `~/.sweep/config.json`：

| mode | apply 的条件 |
|---|---|
| `readonly` | 一律拒绝 |
| `confirm`（默认） | 必须带 plan digest |
| `auto` | 可无 digest，但只允许白名单分类（各类缓存、日志、包管理器、Xcode/IDE/AI 缓存、旧安装包、残留下载）；无分类的条目一律拒绝 |

## 客户端接入

```bash
sweep mcp-config codex      # TOML
sweep mcp-config claude     # JSON（claude / cursor / zcode / workbuddy 通用）
sweep mcp-config dsh        # bundle 说明
```

DSH 已带一个 config-only bundle（`dsh-bundle/`）：`Plugins → Add plugin` 选目录即可，工具以 `mcp__sweep__*` 出现。改动 bundle 后需要重启 DSH，MCP 子进程才会加载新二进制。

## 权限：一个 helper，四端共用

没有完全磁盘访问权限时，`~/Library/Mail`、`Safari`、`Messages`、MobileSync 备份会被跳过，结果里 `deniedPaths` 会列出来并带 `hint`。

直接给某个客户端授权很麻烦——MCP 服务器是被客户端拉起的，会继承客户端的 TCC 身份，四个客户端就要授四次。所以改成：

```bash
sweep helper-install     # 装 Sweep Helper.app + LaunchAgent（固定 bundle id）
sweep fda                # 看当前权限与 helper 状态
```

`helper-install` 后手动做一次：**系统设置 → 隐私与安全性 → 完全磁盘访问权限 → + → 选择 `~/Library/Application Support/SweepHelper/Sweep Helper.app`**（文件选择器里按 ⌘⇧G 粘贴路径）。

三个必须知道的实现细节（都是踩出来的）：

1. **app 必须签名**。直接拼出来的 bundle 没有签名，macOS 看到的是内层二进制的身份（`Identifier=sweep`、`Info.plist=not bound`），你在系统设置里加的 `.app` 和实际跑的进程对不上，授权**不会生效**。`helper-install` 现在会 `codesign --sign - --identifier com.sweep.helper` 把身份钉住。
2. **helper 的二进制被冻结**。ad-hoc 签名绑的是二进制哈希，重新编译就会让授权失效——而失效是**静默的**（开关还是蓝的，但扫描依旧被拒）。所以 `helper-install` 不再覆盖已安装的二进制；要升级 helper 用 `sweep helper-install --force`，然后**重新授权**。
3. **判断授权是否生效，只看扫描结果的 `deniedPaths` 是否为空**。`sweep fda` 与状态图反映的是 helper（通过 `/status` 查询）而不是调用者进程的权限。

授权后重启 helper（`sweep helper-install` 会顺带重启）与 DSH。之后 MCP 的扫描会自动走 helper（请求写队列 `~/.sweep/helper/queue`，helper 执行后写回 `out/`）；helper 不在时自动退回本地子进程，不会失败。

## 已知取舍

- 上游把 `TargetedScanner` 放在 app target，本仓库按同语义复刻（`Walker.swift`）；后续可 PR 上游挪进 kit。
- 目录 URL 的 `path` 带结尾斜杠，节点表按精确路径匹配，`ProjectJunkScan.normalize` 负责归一化。
- 只清理用户空间；`/Library` 等需要 root 的项目只报告不处理。
- 扫描耗时：系统垃圾 ~35s（11.8 万项）。MCP 侧用 `scan_start` → 子进程后台跑 → `scan_status` 轮询，避免请求超时；`scan_large_files` 等快模块仍同步。
- **移入废纸篓不等于释放空间**：需要在访达里清空废纸篓才真正回收，而清空后 `restore_clean` 也就无法还原了。

## 目录

```
Package.swift
install.sh
Sources/SweepAgent/
  Walker.swift          遍历器（对应上游 TargetedScanner）
  SystemJunk.swift      21 个分类
  UserFiles.swift       大文件 / 旧文件 / 重复文件
  ProjectJunkScan.swift 项目树 + 分类
  Operations.swift      快照 / 计划 / 废纸篓 / 审计日志 / 三种模式
  Safety.swift          受保护路径 / digest / 预算
  MCPServer.swift       stdio MCP（11 个工具）
  CLI.swift             子命令
Sources/sweep/main.swift
dsh-bundle/             DSH config-only bundle（含 locale、图标、详情文档）
vendor/               上游扫描引擎源码（BSD-3，见 NOTICE.md）
```
