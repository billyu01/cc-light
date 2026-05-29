# cc-light · Claude Code 红绿灯

为每个跑着 Claude Code 的终端窗口在屏幕上浮一盏小红绿灯，一眼看出哪个在忙、哪个在等你。

```
🔴 红灯  Claude 正在输出
🟡 黄灯  Claude 在等你做选择（数字菜单 / [y/n] 等）
🟢 绿灯  空闲，等你输入
```

## 技术栈

| 层 | 选型 | 备注 |
|---|---|---|
| 语言 | Swift 5.9 | `swift-tools-version: 5.9` |
| 构建 | Swift Package Manager | `swift build -c release`，单一 executable target |
| UI | SwiftUI（漫画风灯泡）+ AppKit（NSPanel 窗口宿主） | SwiftUI 画灯，AppKit 处理窗口浮层和鼠标事件 |
| 进程托管 | AppKit `NSApplication` + `NSStatusItem` | `LSUIElement=true`，无 Dock 图标，状态栏菜单驻留 |
| 终端文本采集 | macOS Accessibility API（`AXUIElement*`） | 只读模式，不模拟键鼠，需要"辅助功能"权限 |
| 进程发现 | `/bin/ps -Ao pid=,ppid=,comm=` | 单次 fork 拉全表，Swift 内走父子关系树 |
| 屏幕窗口枚举 | Core Graphics `CGWindowListCopyWindowInfo` | 拿窗口 ID、frame、所属 pid |
| 调度 | `Timer` + 后台 `DispatchQueue` | 单一 0.5s timer，重活跑后台、UI 切回主线程 |
| 平台 | macOS 13+，Apple Silicon（arm64） | Info.plist `LSMinimumSystemVersion=13.0` |
| 签名 | ad-hoc `codesign -s -` | 没有 Developer ID / Notarization |

依赖：**零第三方依赖**，纯 Apple 系统框架（AppKit / SwiftUI / ApplicationServices / CoreGraphics / Foundation / Combine / os.log）。

## 技术方案

### 整体数据流

```
┌─────────────────────────────────────────────────────────────┐
│  TrafficLightManager  (单一 0.5s Timer)                     │
│                                                             │
│   tick() ── DispatchQueue("com.trafficlight.work") ──┐      │
│                                                      │      │
│   ┌──────────────────────────────────────────────────┘      │
│   │ 1. WindowDetector.detectClaudeWindows()                 │
│   │      ps -A 一次 → 进程表 → 找 claude → 沿 ppid 上溯     │
│   │      → 终端 App pid → CGWindowList 匹配窗口             │
│   │                                                         │
│   │ 2. for 每个窗口:                                        │
│   │      ProcessMonitor.getState(window)                    │
│   │        AXUIElement 取文本                               │
│   │        → stripInputBox() / normalizeForHash()           │
│   │        → 状态机: YELLOW > RED(含1.5s hold) > GREEN      │
│   │                                                         │
│   │ 3. DispatchQueue.main.async {                           │
│   │      diff 增删 NSPanel                                  │
│   │      panel.updatePosition + panel.apply(state:)         │
│   │    }                                                    │
│   └─────────────────────────────────────────────────────────┘
│                                                             │
│  TrafficLightPanel (NSPanel × N，每个 Claude 窗口一个)      │
│    NSHostingView<TrafficLightView>  ←  SwiftUI 画灯泡       │
│    mouseDown/mouseDragged/mouseUp   ←  单击聚焦 / 拖动      │
└─────────────────────────────────────────────────────────────┘
```

### 模块划分（5 个 Swift 文件）

| 文件 | 职责 |
|---|---|
| `main.swift` | 程序入口，创建 `NSApplication` |
| `AppDelegate.swift` | 申请 AX 权限、建状态栏菜单、`setActivationPolicy(.accessory)` 隐藏 Dock 图标、装配三大模块 |
| `WindowDetector.swift` | 一次 `ps -A` 拉全表 → 在内存里走进程树找终端宿主 → CG 拿窗口 → 输出 `[ClaudeWindow]` |
| `ProcessMonitor.swift` | 通过 AX 抓终端文本 → 清洗 → 状态机决策。按 `(pid, windowID)` 隔离每个窗口的历史 |
| `TrafficLightManager.swift` | 唯一调度者：拥有 timer、后台队列、panel 字典；负责 tick / diff / 推送状态 |
| `TrafficLightPanel.swift` | 每个 Claude 窗口对应的 `NSPanel`，承载 SwiftUI 视图，处理鼠标事件 |

### 三个关键设计决策

**1. 状态判定不依赖关键字猜测，靠"输出区 hash 是否在变"。**
天真的"匹配 ✓ / done / 任务完成"在中英文混杂、自定义提示词下完全不可靠。我们改成：把 ANSI 转义、Claude Code 的盲文 spinner（`⠋⠙⠹...`）、`(Ns · esc to interrupt)` 计时器、所有数字、底部输入框区域（按 `╭─╮│╰╯` 边框识别）从屏幕文本里全部剔除，再算 hash。**剩下的就是"真正的输出"**。Hash 一变 → RED；最近一次变化算起的 1.5 秒内继续 RED（去抖，避免 spinner 抖动让灯 1Hz 闪烁）；超时 → GREEN。YELLOW 优先级最高，匹配数字菜单 / `[y/n]` 等。

**2. 重活全部丢到后台队列，主线程只摸 UI。**
最早的版本把 `ps` / `pgrep` / AX 调用都放在主线程的 timer 回调里。`-[NSConcreteTask waitUntilExit]` 是同步阻塞，单次 tick 累计 200-500ms，鼠标 hover 上去主线程没空响应 → 光标变 spinner。改造后：`com.trafficlight.work` 串行队列里完成所有 fork+exec 和 AX 树遍历，**主线程只负责创建/关闭 panel、设置位置、setColor**。CPU 从 27% 降到 7%，RSS 从 261 MB 降到 50 MB。

**3. 用 `(pid, windowID)` 而不是仅 pid 隔离窗口状态。**
同一个终端 App（如 iTerm2）能开多个窗口，pid 是 App 级的，不能区分窗口。这导致两盏灯互相窜状态。修复：状态字典用复合键，`getTerminalContent` 时按 `kAXPositionAttribute / kAXSizeAttribute` 与目标 frame 做最近匹配，挑出正确的那个 AX 窗口。

### 鼠标事件路径

`NSPanel` 的 `mouseDown` 不能直接调 `performDrag(with:)`——后者是阻塞的，泵主线程 run loop 直到鼠标抬起，纯按一下不动会卡光标。正确拆法：

| 事件 | 行为 |
|---|---|
| `mouseDown` | 记起点，立即返回 |
| `mouseDragged` | 移动 > 4px 才启动 `performDrag`（确认是真拖动） |
| `mouseUp` | 没拖过 → 单击 → `focusTerminal()` |

`focusTerminal()` 走 AX：`AXUIElementCopyAttributeValue(... kAXWindowsAttribute ...)` 拿到 App 全部窗口 → 按 frame 匹配到目标 → `kAXRaiseAction` + `kAXMainAttribute=true` + `kAXFocusedAttribute=true` → 最后再 `NSRunningApplication.activate` 把 App 拉到最前。**先 raise 后 activate**，确保多窗口时打到正确窗口。

### 调试

运行时所有内部决策都写到 `/tmp/trafficlight_debug.log`，格式：

```
[14:34:55] [windowID] 状态 (原因)
[14:34:55] [563] RED (output changed)
[14:34:55] [606] RED (hold, 0.48s since last change)
[14:34:56] [1266] YELLOW (selection prompt)
```

`tail -f` 实时看，能直接定位"为什么这盏灯现在是这个颜色"。

## 使用手册

### 1. 安装

项目自带打包好的 `TrafficLight.app`。把它拖到 `/Applications` 或者直接双击运行即可。

如果你修改了源码，自己出一份新二进制：

```bash
cd TrafficLight
swift build -c release
cp .build/release/TrafficLight ../TrafficLight.app/Contents/MacOS/TrafficLight
codesign --force --deep --sign - ../TrafficLight.app
```

### 2. 第一次启动 — 授权辅助功能

应用必须有「辅助功能」权限才能读到终端文本。

1. 启动 `TrafficLight.app`
2. 系统会弹"TrafficLight 想要控制您的电脑"
3. 点"打开系统设置" → 在「隐私与安全性 → 辅助功能」里勾上 **TrafficLight**
4. 关掉再重开一次 app

> ⚠️ 如果你重新编译过二进制，旧授权会失效。把列表里的旧 `TrafficLight` 条目用减号删掉，再启动新版重新授权。必要时执行：
> ```bash
> tccutil reset Accessibility com.trafficlight.app
> ```

### 3. 日常使用

启动后它会自己住在状态栏（顶栏右侧）里，没有 Dock 图标。每发现一个跑着 Claude Code 的终端窗口，就在该窗口左上角浮一盏灯。

| 操作 | 行为 |
|---|---|
| **单击灯** | 把对应的终端窗口提到最前并激活 |
| **拖动灯** | 把灯挪到任意位置（按住 → 拖 → 放开） |
| **状态栏图标 → 退出** | 退出整个程序 |

终端窗口被关掉，对应的灯会自动消失；新开的 Claude Code 终端会自动出现新的灯。

### 4. 卸载

```bash
pkill -f TrafficLight
rm -rf TrafficLight.app
tccutil reset Accessibility com.trafficlight.app
```

## 状态判定规则

每 0.5 秒采样一次 AX 文本：

- 状态优先级：**黄 > 红 > 绿**
- **黄**：尾部出现 `1. ... 2. ... 3.` / `[1] [2]` / `[y/n]` 等选项 prompt
- **红**：文本经清洗后实际发生了变化；最后一次变化算起的 1.5 秒内保持红，避免 spinner 抖动
- **绿**：上述都不满足

清洗会剔除：ANSI 转义、盲文 spinner（`⠋⠙⠹...`）、`(Ns · esc to interrupt)` 计时、所有数字、底部的 TUI 输入框区域（按 `╭─╮│╰╯` 等 box-drawing 字符识别）。

正因为输入框被剔除，**用户在输入框里打字不会触发红灯**。

## 限制（已知）

### 平台

- 仅支持 **macOS 13+**（用到了 SwiftUI 新 API、`.fullScreenAuxiliary` 等）
- 仅支持 **Apple Silicon（arm64）**。Intel Mac 需要自己重新 `swift build`，没测过
- 没做 Notarization / Developer ID 签名，自带的是 ad-hoc 签名。Gatekeeper 第一次会拦截，右键 → "打开" 可绕过

### 终端兼容性

只识别下列终端 App 的窗口，靠 `comm` 字符串包含匹配：

```
Terminal · iTerm / iTerm2 · Ghostty · Alacritty · Kitty · Warp · Hyper · WezTerm · Tabby
```

其他终端（Tabby 之外的小众、tmux-only 工作流、远程 SSH 终端代理）不会被识别。要加，改 `WindowDetector.terminalNames`。

### Claude 进程识别

按 `comm == "claude"` 精确匹配。如果你用 wrapper / alias / 不同二进制名启动 Claude Code（比如 `claude-dev`），不会被识别。改 `WindowDetector.detectClaudeWindows()` 里的判断即可。

### 多窗口聚焦的精度

单击聚焦时按 AX 窗口的 `position + size` 与 CGWindow 的 frame 做最近匹配。如果你把两个尺寸位置完全相同的终端窗口叠在一起，可能聚焦错误。一般用户不会这么用。

### 状态判定的局限

- 状态机基于关键字 + 内容 hash，**不是真正读 Claude Code 进程的内部状态**。罕见情况下：
  - 输出停下后 1.5 秒内才会落绿（这是去抖窗口，不是 bug）
  - 如果终端的 AX 实现不返回完整文本（少见），状态会停留在最近一次有效值
- 不识别 Claude Code 的所有 prompt 形式。新出现的菜单格式可能落不到黄灯。改 `ProcessMonitor.looksLikeSelectionPrompt` 添加规则
- 单实例假设：同一个终端窗口里如果有多个 Claude Code 进程交替前台运行，灯只反映"屏幕上现在显示的那一个"

### 性能

- 每 0.5 秒一次后台 tick，包含一次 `ps -A` 调用 + 每个窗口一次 AX 树遍历
- 实测 CPU ~7%、RSS ~50 MB（M 系列芯片，3-4 个 Claude 窗口在跑）
- 如果 CPU 异常飙高或鼠标 hover 卡顿，几乎一定是辅助功能权限失效或 AX 调用阻塞——重启 app + 重新授权
- 调试日志写在 `/tmp/trafficlight_debug.log`，每次 tick 追加，**长时间运行会一直增长**。临时调试可以 `tail -f`，长期使用建议自己加 logrotate 或注释掉日志写入

### 行为

- 灯使用 `NSPanel` 浮在最前层（`.canJoinAllSpaces`、`.fullScreenAuxiliary`），全屏 Spaces 也可见
- 灯的位置每个 tick 会**重新跟随终端窗口**——即便你拖动了它，下一个 tick 会被拉回到对应终端的左上角。如果想改成"位置记忆"，需要改 `TrafficLightPanel.updatePosition`
- 退出应用：状态栏图标 → 退出。**没有 Cmd+Q**（应用是 `.accessory` 类型，不在 Dock 里）
