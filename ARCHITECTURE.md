# Daily 架构

macOS 日程聚合日历：把课程、日历、邮件/微信、交通、快递外卖、订阅、Agent 写入等来源统一成一种「日程条目」，在主窗口和桌面小组件里展示。界面风格采用 **A · 原生简洁**。

## 目录

```
Daily/
├── project.yml                 # XcodeGen 工程描述（App + Widget），生成 Daily.xcodeproj
├── App/                        # macOS App 目标：入口、Info.plist、entitlements
├── Widget/                     # WidgetKit 扩展
└── Packages/DailyKit/          # 所有业务代码，SwiftPM 包，命令行即可 build/test
    ├── Sources/DailyKit/       # 核心：模型、存储、数据源、同步（无 UI）
    │   ├── Model/              # CalendarItem、SourceKind、Subscription …
    │   ├── Store/              # ItemStore（系统 SQLite3，放在 App Group 容器）
    │   ├── Sources/            # 各数据源 Provider（ICS、EventKit、教务、IMAP …）
    │   └── Sync/               # SyncEngine：拉取 → 去重 → 写库
    ├── Sources/DailyUI/        # SwiftUI 视图，App 与 Widget 共用
    ├── Sources/DailyDev/       # 开发用可执行文件：不装 Xcode 也能跑主窗口
    └── Tests/DailyKitTests/
```

## 数据流

```
来源 Provider ──fetch(range)──▶ SyncEngine ──upsert/清理──▶ ItemStore (SQLite)
                                                        │
             Agent 接口 / AI 识别 ──insert(pending)──────┤
                                                        ▼
                                          App 主窗口 / Widget 读取
```

- **统一模型** `CalendarItem`：每条带 `sourceKind`（大类，决定颜色）、`sourceID`（具体哪个账号/订阅）、`externalID`（来源内唯一键，用于去重）。
- **只读聚合**：外部来源只读不回写；用户手动建的条目 `sourceKind = .manual`。
- **待确认**：AI 从邮件/微信等识别出的条目以 `status = .pending` 入库，用户确认后才显示在日历里。
- **同步**：每个 Provider 每次返回某时间范围内的完整快照；SyncEngine 在该范围内按 `(sourceID, externalID)` upsert，并删除快照里已消失的条目。
- **App 与 Widget 共享数据**：数据库放在 App Group 容器。Widget 只有一处写入：在「待取件」小组件上点「已取」，把条目标为 dismissed，并把中转服务 ID 放进 `parcelPicks` 队列，再发一个 Darwin 通知；App 收到后（或下次同步时）去中转服务删除。小组件本身不联网。
- **手动日程**：`sourceID = "manual"`，没有 Provider 管它，同步不会覆盖；只有这类条目能在 App 里编辑和删除。可以标为「交通出行」，这样也会有出行提醒。
- **提醒**：只提醒出行、取件码、订阅续费三类。`ReminderPlanner` 根据数据和设置算出要发的通知（纯函数，有测试），`ReminderScheduler` 把结果同步到系统通知中心：多的撤掉、缺的补上。定时通知由系统负责，App 没在运行也会弹出；「收到取件码」是 App 同步到新快递时立即发出的。
- **后台运行**：关掉主窗口后 App 留在菜单栏（Dock 图标隐藏），继续同步。登录时自动打开（`SMAppService`）的情况下不弹出主窗口。

## 数据源路线

| 阶段 | 来源 | 方式 |
|---|---|---|
| P0 | 手动、ICS 订阅、系统日历 | ICS 解析（含重复规则展开）、EventKit |
| P0 | 订阅管理 | 本地录入，按周期自动生成续费提醒 |
| P1 | 教务课程 | 视学校教务系统类型（正方/强智/青果/URP…）做登录+课表解析 |
| P1 | Agent / Bot 写入 | 本机 HTTP 接口 + App Intents（快捷指令）+ MCP server |
| P2 | 邮件、微信、短信、交通、快递 | IMAP 读取 / 分享与粘贴 → 可切换 LLM（OpenAI 兼容，如 DeepSeek）识别 → 待确认 |

## 约定

- 最低系统 macOS 15（`defaultLaunchBehavior` 等）。
- 无付费开发者账号：使用 Personal Team 签名。
- 数据层预留同步抽象，未来可接 CloudKit / iPhone 版。

## 开发

不装 Xcode 也能开发核心逻辑和界面（只有 Command Line Tools 时）：

```bash
scripts/test.sh                                              # 跑全部测试
cd Packages/DailyKit && swift run DailyDev                   # 用示例数据打开主窗口
swift run DailyDev --snapshot week.png --now 15:10           # 主窗口截图（--dark、--mode month|list|day）
swift run DailyDev --widgets widgets.png --now 15:10         # 桌面小组件截图
```

装好 Xcode 之后：`brew install xcodegen && xcodegen generate`，打开 `Daily.xcodeproj`，在 Signing 里选 Personal Team，运行 `Daily` scheme。

改了小组件（新增种类、改尺寸）后要提高 `project.yml` 里的 `CURRENT_PROJECT_VERSION` 再编译，必要时 `killall chronod`，否则「编辑小组件」里还是旧列表。

只有 Command Line Tools 时的两个坑：
- macOS 27 SDK 里 `@State` 是宏，插件只随 Xcode 提供，所以 `DailyUI` 里不用 `@State`，视图状态放进 `CalendarModel`。
- swift-testing 的宏插件要用 `-plugin-path` 在编译器进程内加载，`scripts/test.sh` 已处理。
