import AppKit
import DailyKit
import DailyUI
import SwiftUI

// 开发用启动器：不需要 Xcode，用示例数据打开主窗口。
//   swift run DailyDev                      打开窗口
//   swift run DailyDev --snapshot out.png   把主窗口渲染成 PNG（无需屏幕录制权限）
//   swift run DailyDev --snapshot out.png --dark --mode month
//   swift run DailyDev --widgets out.png --now 15:10      渲染桌面小组件

@MainActor
func makeModel(now: Date? = nil) -> CalendarModel {
    let store = try! ItemStore.inMemory()
    try! DemoData.seed(store)
    let model = CalendarModel(store: store, now: { now ?? .now })
    model.lastSync = .now
    model.calendarAccess = .granted
    model.systemCalendars = [
        SystemCalendarInfo(id: "home", title: "个人", accountName: "iCloud", colorHex: "#0F8B8D"),
        SystemCalendarInfo(id: "family", title: "家庭", accountName: "iCloud", colorHex: "#FF9500"),
        SystemCalendarInfo(id: "work", title: "社团", accountName: "Google", colorHex: "#AF52DE"),
        SystemCalendarInfo(id: "holiday", title: "中国节假日", accountName: "其他", colorHex: "#34C759"),
    ]
    model.excludedCalendarIDs = ["holiday"]
    return model
}

let args = CommandLine.arguments
let app = NSApplication.shared

/// `--now 15:10`：把「现在」固定成今天的某个时刻，方便截图。
let fixedNow: Date? = args.firstIndex(of: "--now").flatMap { i -> Date? in
    let parts = args[i + 1].split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 else { return nil }
    return Calendar.mondayFirst.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: .now)
}

struct WidgetGallery: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            card(TodayAgendaWidgetView(snapshot: snapshot), width: 364, height: 382)
            VStack(spacing: 24) {
                card(NowNextWidgetView(snapshot: snapshot), width: 364, height: 170)
                HStack(spacing: 24) {
                    card(SubscriptionWidgetView(snapshot: snapshot), width: 170, height: 170)
                    card(TripWidgetView(snapshot: snapshot), width: 170, height: 170)
                }
            }
        }
        .padding(34)
        .background(Color(red: 0.72, green: 0.76, blue: 0.81))
    }

    private func card(_ content: some View, width: CGFloat, height: CGFloat) -> some View {
        content
            .padding(16)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(nsColor: .windowBackgroundColor)))
    }
}

@MainActor
func render(_ view: some View, size: NSSize, dark: Bool, to path: String) {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = NSHostingView(rootView: view)
    window.setContentSize(size)
    window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    guard let content = window.contentView,
          let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(1) }
    content.cacheDisplay(in: content.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("saved \(path)")
}

/// 「接下来几天」三种尺寸。
struct UpcomingGallery: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 24) {
                card(UpcomingWidgetView(snapshot: snapshot, layout: .medium), width: 364, height: 170)
                card(UpcomingWidgetView(snapshot: snapshot, layout: .large), width: 364, height: 382)
            }
            card(UpcomingWidgetView(snapshot: snapshot, layout: .extraLarge), width: 772, height: 382)
        }
        .padding(34)
        .background(Color(red: 0.16, green: 0.17, blue: 0.2))
    }

    private func card(_ content: some View, width: CGFloat, height: CGFloat) -> some View {
        content
            .padding(16)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(nsColor: .windowBackgroundColor)))
    }
}

/// 新增的小组件：待取件、订阅（中号）、出行。
struct ExtraWidgetGallery: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 24) {
                card(ParcelWidgetView(snapshot: snapshot, wide: false) { _ in EmptyView() }, width: 170, height: 170)
                card(ParcelWidgetView(snapshot: snapshot, wide: true) { _ in
                    Button("已取") {}.buttonStyle(.bordered).controlSize(.small)
                }, width: 364, height: 170)
            }
            HStack(spacing: 24) {
                card(SubscriptionWidgetView(snapshot: snapshot), width: 170, height: 170)
                card(SubscriptionWidgetView(snapshot: snapshot, wide: true), width: 364, height: 170)
            }
            card(TripWidgetView(snapshot: snapshot), width: 170, height: 170)
        }
        .padding(34)
        .background(Color(red: 0.72, green: 0.76, blue: 0.81))
    }

    private func card(_ content: some View, width: CGFloat, height: CGFloat) -> some View {
        content
            .padding(16)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(nsColor: .windowBackgroundColor)))
    }
}

/// `--panel <名字> out.png`：设置各页、菜单栏、订阅管理、编辑表单、搜索结果。
if let i = args.firstIndex(of: "--panel"), i + 2 < args.count {
    let name = args[i + 1], path = args[i + 2]
    MainActor.assumeIsolated {
        app.setActivationPolicy(.prohibited)
        let model = makeModel(now: fixedNow)
        let dark = args.contains("--dark")
        switch name {
        case "general", "reminders", "sources", "relay":
            let tab: SettingsView.Tab = switch name {
            case "reminders": .reminders
            case "sources": .sources
            case "relay": .relay
            default: .general
            }
            model.notificationAccess = .granted
            render(SettingsView(model: model, tab: tab), size: NSSize(width: 500, height: tab == .reminders ? 640 : 480),
                   dark: dark, to: path)
        case "menubar":
            render(MenuBarView(model: model) {}, size: NSSize(width: 300, height: 560), dark: dark, to: path)
        case "subscriptions":
            render(SubscriptionsView(model: model), size: NSSize(width: 460, height: 520), dark: dark, to: path)
        case "editor":
            var draft = EventDraft(start: .now, calendar: model.calendar)
            draft.kind = .travel
            draft.title = "G1234 上海虹桥 → 北京南"
            draft.isNew = false
            render(EventEditorView(model: model, draft: draft), size: NSSize(width: 420, height: 620), dark: dark, to: path)
        case "search":
            model.searchText = "数"
            render(MainWindowView(model: model), size: NSSize(width: 1200, height: 760), dark: dark, to: path)
        case "widgets":
            let snapshot = try! WidgetSnapshot.load(from: model.store, now: fixedNow ?? .now)
            render(ExtraWidgetGallery(snapshot: snapshot), size: NSSize(width: 640, height: 640), dark: dark, to: path)
        default:
            print("unknown panel \(name)")
        }
    }
    exit(0)
}

if let i = args.firstIndex(of: "--upcoming"), i + 1 < args.count {
    MainActor.assumeIsolated {
        app.setActivationPolicy(.prohibited)
        let store = try! ItemStore.inMemory()
        try! DemoData.seed(store)
        let snapshot = try! WidgetSnapshot.load(from: store, now: fixedNow ?? .now)
        render(UpcomingGallery(snapshot: snapshot), size: NSSize(width: 840, height: 1060),
               dark: args.contains("--dark"), to: args[i + 1])
    }
    exit(0)
}

if let i = args.firstIndex(of: "--widgets"), i + 1 < args.count {
    MainActor.assumeIsolated {
        app.setActivationPolicy(.prohibited)
        let store = try! ItemStore.inMemory()
        try! DemoData.seed(store)
        let snapshot = try! WidgetSnapshot.load(from: store, now: fixedNow ?? .now)
        render(WidgetGallery(snapshot: snapshot), size: NSSize(width: 820, height: 450),
               dark: args.contains("--dark"), to: args[i + 1])
    }
    exit(0)
}

if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    let mode = args.firstIndex(of: "--mode").flatMap { j in
        ViewMode.allCases.first { "\($0)" == args[j + 1] }
    } ?? .week
    MainActor.assumeIsolated {
        app.setActivationPolicy(.prohibited)
        let model = makeModel(now: fixedNow)
        model.mode = mode
        render(MainWindowView(model: model), size: NSSize(width: 1200, height: 760),
               dark: args.contains("--dark"), to: args[i + 1])
    }
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Daily"
            window.contentView = NSHostingView(rootView: MainWindowView(model: makeModel()))
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.window = window
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
