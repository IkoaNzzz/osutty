# Otty 右侧 Sidecar 调研

> 调研日期：2026-07-25
>
> 环境：macOS，Otty 当前安装版本（本机已登录会话），窗口约 `976 × 671 pt`
>
> 方法：通过 macOS Accessibility Tree、截图和实际交互验证；未依据宣传材料推断功能。

## 1. 目标与结论

目标是在 Ghostty macOS 原生应用中复刻 Otty 的右侧详情面板，同时：

- 尽量把改动收敛到新的 `Sidecar` feature，降低后续合并 Ghostty upstream 的冲突成本。
- 不阻塞终端渲染、PTY I/O 或主线程。
- 使用 SwiftUI / AppKit 原生控件，保留 Otty 的轻量浮层风格，但颜色、材质、分隔线和焦点行为跟随 Ghostty。

Otty 的右侧区域不是一个普通“文件树”，而是窗口级、跟随当前活跃 terminal pane 的四模式详情面板：

1. Info
2. Outline
3. Git
4. Files

Ghostty 最合适的挂载点是 `TerminalView` 的窗口级内容层，而不是每个
`TerminalSplitLeaf`。数据源应跟随 `lastFocusedSurface`，这样有多个 pane 时只保留一个
Sidecar，并随焦点切换工作目录和内容。

## 2. 外观与布局实测

### 2.1 窗口关系

- Sidecar 位于终端右侧，占用布局空间，不覆盖终端文本。
- 终端和 Sidecar 之间有可拖动 divider。
- 详情内容本身是带圆角、阴影和半透明材质的 inset card；终端背景延伸到 card 周围。
- card 距窗口右、上、下边缘留有小间距，视觉上类似 macOS inspector/popover。
- 顶部使用四个 SF Symbols 风格图标；当前模式显示图标和文字，并放在浅色 capsule 内。
- 内容标题使用系统字体；命令和路径适合使用等宽字体。
- 链接和主要动作使用系统 accent color。

### 2.2 宽度

在约 `976 pt` 宽的窗口中实测：

- 默认 divider x 坐标约 `756`，Sidecar 区域约 `220 pt`。
- 可缩到约 `140 pt`。
- 可放大到约 `500 pt`，即窗口宽度约一半。
- 拖动结束后模式和内容状态保持不变。

Ghostty 实现不应照搬固定像素。建议：

- 默认宽度：`240 pt`
- 最小宽度：`180 pt`（保证 Git 操作和文件名仍可用）
- 最大宽度：`min(520 pt, windowWidth * 0.5)`
- 记住每个 window 的用户宽度；窗口恢复时 clamp 到当前可用范围。

### 2.3 显示与导航

- `显示 → 切换详情面板` 可以整体显示/隐藏 Sidecar。
- `显示` 菜单可直接切换 Info / Outline / Git / Files；切换目标模式时应自动显示 Sidecar。
- 当前模式在 Sidecar 顶部有明确选中态。
- Sidecar 隐藏后终端立即恢复全部宽度。

## 3. 功能清单

### 3.1 Info

#### 已验证内容

- Working Directory
  - 路径使用 `~` 缩写，例如 `~/Code/naoki/ghostty`。
  - `Copy Path`
  - `Reveal in Finder`
  - `Open in VS Code`
  - `Open in Cursor`
  - `Open in Xcode`
  - `Open in Zed`
- Process
  - 展示当前前台进程与父 shell。
  - 每项包括进程名、PID 和持续时间。
  - 运行 `python3 -m http.server ...` 时，面板从单一 `-zsh` 更新为
    `python3 → -zsh`。
- Ports
  - 无结果时显示 `No listening ports`。

#### 实测缺陷

使用：

```sh
python3 -m http.server 8765 --bind 127.0.0.1
```

外部通过 `lsof` 确认 PID `50156` 正在监听 `127.0.0.1:8765`，Otty 已正确显示该
Python 子进程，但超过 20 秒后 Ports 仍显示 `No listening ports`。

Ghostty 实现应覆盖 loopback listener，并为结果标明 address、port 和所属 PID。端口扫描必须
只检查当前 pane 的进程树，不允许全系统高频 `lsof`。

### 3.2 Outline

#### 已验证内容

- 按工作目录分组，而不是单一平铺列表。
- 分组头显示缩写路径和相对时间，例如：
  - `~/ · 9m ago`
  - `~/Code/naoki/ghostty/ · 32s ago`
- 分组内按顺序列出执行过的命令。
- shell `cd` 后会产生新的工作目录分组。
- 点击命令会把 terminal scrollback 跳转到对应命令位置。
- 跳转后 Sidecar 保持打开，terminal 出现滚动条，目标命令在可视区域内。

#### 数据语义

Outline 依赖 shell integration / OSC 133 semantic prompt 标记。只解析 prompt 字符串会被：

- 自定义 prompt
- 多行命令
- shell 主题
- tmux
- 宽字符与换行

破坏，因此不能把“正则解析终端文本”作为正式实现。

Ghostty core 已保存 semantic prompt 信息，并支持 `jump_to_prompt`，但当前 macOS C/Swift API
没有列出 command history 和直接跳到指定 prompt ID 的接口。完整复刻需要一个窄的、只读的
core snapshot API；这会是 Sidecar 唯一必须触及 Zig/C 边界的部分。

### 3.3 Git

#### clean repository 已验证内容

- 当前 branch：`main`
- 同步状态：`up to date`
- remote URL：`https://github.com/IkoaNzzz/ghostty`
- `Working tree clean` 空状态
- `Commit` 主动作和下拉区
- repository editor 快捷入口，默认显示 Cursor
- editor 下拉项：
  - VS Code
  - Xcode
  - Zed
- Git 更多操作：
  - Push
  - Pull
  - Fetch
  - Merge…
  - Rebase…
- dirty repository
  - 按 `Staged` / `Unstaged` 分组并显示数量。
  - Unstaged header 提供 `Stage all`。
  - tracked modification 使用 `M` 标记。
  - untracked path 使用 `?` 标记。
  - 完全 untracked 的目录被折叠成一条目录记录，例如 `? docs/`，不会立即枚举所有子文件。
  - branch 右侧会显示 diff 统计；临时增加一行后显示 `+1`。
- Commit
  - 打开独立原生窗口，不占用 Sidecar。
  - 提供 commit message 多行输入。
  - 提供 `Stage All` / `Unstage All`。
  - 文件列表提供逐项 checkbox。
  - `Cancel` 和 `Commit` 为独立动作。

#### 待验证

- 单文件 stage / unstage / discard 行为
- merge conflict 状态
- ahead / behind / detached HEAD
- 无 remote、bare repository、submodule/worktree
- Commit hook 失败、签名和 amend 行为

这里记录的是 Otty 产品本身仍未逐项实测的行为。Ghostty Sidecar 的实现另外使用真实临时
repository 覆盖了 unborn HEAD、单文件/all stage 与 unstage、merge conflict、ahead/behind、
detached HEAD 和无 remote；详见 [`COMPLETION_AUDIT.md`](COMPLETION_AUDIT.md)。

### 3.4 Files

#### 已验证内容

- root 默认跟随 terminal 当前工作目录。
- 目录优先、文件其次，名称升序。
- 目录可原地 lazy expand / collapse。
- `Toggle Hidden Files`
  - 关闭时隐藏 dotfiles。
  - 打开时显示 `.agents`、`.git`、`.github` 以及各类 dotfiles。
- `Go to Folder…`
  - 原生 modal dialog。
  - 默认填入当前浏览 root。
  - 接受绝对路径。
- `Go to Parent Folder`
  - 只改变 Files 的浏览 root。
  - 不改变 terminal 的工作目录。
- 文件搜索
  - 输入后按 Return 执行。
  - 在整个浏览 root 下递归按文件名搜索。
  - 结果显示相对路径，例如 `src/cli/README.md`。
  - 在 Ghostty repository 中搜索 `README`，交互调用约 1 秒内返回大量结果。
- 文件选择与预览
  - 单击选择文件。
  - Space 使用系统 Quick Look 打开独立原生预览窗口。
  - Quick Look 提供系统 Share 和 `Open with <default app>`。
  - 再按 Space 关闭预览并回到文件树。

#### 未发现

- Sidecar 内嵌文本编辑器。
- 文件写入、重命名、删除入口。

第一版应保持浏览器只读，避免在 terminal app 内复制 Finder/IDE 的高风险写操作。

## 4. Ghostty 架构映射

### 4.1 现有可复用能力

- `TerminalView`
  - 窗口级 SwiftUI root。
  - 已维护 `lastFocusedSurface`。
  - 已通过 FocusedValue 获取活跃 pane 的 `pwd`。
- `BaseTerminalController`
  - `TerminalViewModel` 的 AppKit owner。
  - 已持有 `focusedSurface` 和 `surfaceTree`。
  - 适合保存 window-scoped Sidecar 显示、模式和宽度状态。
- `Ghostty.SurfaceView`
  - `@Published var pwd`
  - `surfaceModel.foregroundPID`
  - `title`
  - 已有 500ms TTL 的 screen/visible text cache。
- `SplitView`
  - Ghostty 自有 SwiftUI divider。
  - 可用于窗口级 horizontal split，但需要增加合理 min/max size，而不是当前通用的 `10 pt`。
- `ghostty_surface_binding_action`
  - 可以执行 `jump_to_prompt` 等已有 binding action。
- macOS Quick Look
  - 文件预览应直接调用系统 Quick Look，不自行解析或渲染大文件。

### 4.2 推荐隔离边界

新增目录：

```text
macos/Sources/Features/Sidecar/
  SidecarView.swift
  SidecarViewModel.swift
  SidecarState.swift
  Info/
  Outline/
  Git/
  Files/
  Services/
macos/Tests/Sidecar/
```

现有文件的必要改动控制为：

1. `TerminalView.swift`
   - 在 terminal content 外包一层窗口级 horizontal layout。
   - 传入 `lastFocusedSurface`。
2. `TerminalViewModel`
   - 增加一个聚合的 `sidecarState`，避免散落多个 property。
3. `BaseTerminalController.swift`
   - owner / restore state / action routing。
4. macOS menu / keybind action 的单一接线点。
5. Outline 所需的最小 C/Zig snapshot API。

不应修改 terminal renderer、PTY read/write hot path、每帧 Metal callback 或
`TerminalSplitTreeView` 的递归结构。

### 4.3 上游同步策略

- 所有业务逻辑放在新增文件中。
- 对现有文件使用小型 adapter，不把 Sidecar 分支嵌进既有复杂 switch。
- 不改写现有 Inspector；Ghostty Inspector 是每个 surface 的调试工具，并且开启后会让
  Termio 进入逐字节的 slow mode，不适合作为用户 Sidecar。
- Core API 使用追加式 ABI，不改变已有 struct layout。
- 单独维护 `sidecar` feature commit；upstream 更新时可先 rebase core adapter，再处理 UI。

## 5. 性能设计与风险

### 5.1 明确预算

Release 构建建议验收目标：

- Sidecar 隐藏：
  - 不创建 file watcher、Git process、递归 enumerator 或 timer。
  - terminal throughput / frame time 相对 upstream 的变化在测量噪声内。
- Sidecar 可见但 idle：
  - 主线程每秒额外 CPU 平均 `< 0.5 ms`。
  - 不进行周期性全目录扫描。
- pane/cwd 切换到首屏内容：
  - Info / Files root `< 100 ms`。
  - Git `< 250 ms`（普通本地 repository）。
- 文件搜索：
  - 可取消。
  - 结果分批发布。
  - 默认最多 `500` 条。
  - 不跟随每个 keystroke 启动不可取消的全树遍历。
- Git refresh：
  - 同一 repository 最短间隔 `250 ms`。
  - 并发最多一个 snapshot，后续事件 coalesce。
- Outline snapshot：
  - 按需拉取，隐藏时不更新 UI。
  - 上限建议最近 `500` 个 command。

### 5.2 风险点

| 风险 | 影响 | 约束/方案 |
|---|---|---|
| SwiftUI `body` 内直接做 I/O | 输入和 resize 卡顿 | 所有 filesystem/Git/process 查询放到 actor/background task |
| 对大 repository 高频 `git status` | CPU、磁盘、进程抖动 | 单次 porcelain v2 snapshot + debounce + cancellation |
| 每次展开重扫全树 | 大 monorepo 卡顿 | 目录按节点 lazy load，缓存 key 使用 URL + metadata generation |
| 搜索结果一次性发布 | 主线程 diff 爆发 | 后台遍历、批量 `50` 条、结果 cap |
| 全系统端口扫描 | 高 CPU、隐私扩大 | 只遍历 foreground process tree 的 FDs |
| Outline 解析 screen text | 错误、复制大量 scrollback | core semantic-prompt snapshot API |
| Sidecar 观察所有 pane | 隐藏成本和无效刷新 | 只激活 focused surface 的 service，切换时 cancel |
| Quick Look 自行读大文件 | 内存峰值、格式不全 | 使用 `QLPreviewPanel` / `QLPreviewItem` |
| 文件 watcher 监听整个 monorepo | event storm | watcher 仅作 invalidation，debounce 后按需 snapshot |
| Debug 构建性能误判 | 无法代表用户体验 | 功能用 Debug，性能必须用 Release profile |

## 6. 建议分阶段实现

### Phase A：原生壳与状态

- window-scoped Sidecar 显示/隐藏、模式切换、悬浮卡片。
- 跟随 active pane。
- Info 的 cwd 与基础 process。
- Files 的 lazy tree、hidden toggle、Go to Folder、Quick Look。
- Git branch/status/read-only file list。

### Phase B：完整交互

- Git stage/unstage/commit/fetch/pull/push/merge/rebase，所有 destructive/disruptive action 带清晰确认。
- Info editor actions 与准确 ports。
- recursive filename search。
- state restoration 和 keybindings。

### Phase C：Outline core API

- 增加 semantic command snapshot。
- 按 cwd 分组、相对时间、exit status/duration。
- 通过稳定 command/prompt ID 定位 scrollback。
- tmux、超长 scrollback、历史截断测试。

### Phase D：性能和兼容

- ETTrace / Instruments 对比 Sidecar hidden、idle、Git churn、large tree search。
- light/dark、透明背景、macOS 13–26、Liquid Glass。
- 多 pane、多 tab、Quick Terminal、native fullscreen、window restoration。

## 7. 验收清单

- [x] Sidecar 显示/隐藏不改变 pane tree 或 terminal grid。
- [x] 焦点 pane 变化后窗口级 Sidecar 切到新的 surface/cwd（Info 实机验证）。
- [x] 四个模式切换 pane/隐藏时终止旧 view task；Files 长搜索实机验证，Git process cancellation 自动测试。
- [x] Info 的 cwd/process/ports 与系统事实一致。
- [x] Outline 命令列表来源于 semantic prompt，不依赖 prompt regex。
- [x] 点击 Outline 项准确定位对应 scrollback。
- [x] Git clean/dirty/staged/conflict/ahead/behind 状态正确（真实临时 repositories）。
- [x] Files lazy expand、hidden、parent、go-to、search、Quick Look 完整。
- [x] Sidecar 隐藏时零后台轮询。
- [x] Release 隐藏态与 upstream 的持续 CPU/内存开销处于测量噪声内；可见 Info 中位 CPU 约 0.2%。
- [x] UI 在 Ghostty light/dark/透明主题下均保持原生可读性。
- [x] upstream 同步边界为 7 个 adapter 文件、206 行追加、0 行删除；当前 upstream 与 base 相同。

性能原始方法、数字和限制见 [`PERFORMANCE.md`](PERFORMANCE.md)。最终悬浮布局已通过 Computer
Use 在真实 Debug app 中完成四面板、标题栏开关和快捷键开关验证。为避免只靠屏幕捕获判断
兼容性，单元测试还会离屏渲染生产 `SidecarChrome`，使用安装包中 3024 Day 的
`#f7f7f7`、3024 Night 的 `#090300` 和 `0.62` 透明终端背景检查实际像素
luminance/alpha。
