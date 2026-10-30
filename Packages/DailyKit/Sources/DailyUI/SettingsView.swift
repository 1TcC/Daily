import DailyKit
import SwiftUI

/// 设置窗口（⌘,）：通用、提醒、数据来源、AI 连接。
public struct SettingsView: View {
    public enum Tab: Hashable, Sendable { case general, reminders, sources, relay }

    @Bindable var model: CalendarModel
    @State private var tab: Tab

    public init(model: CalendarModel, tab: Tab = .general) {
        self.model = model
        _tab = State(initialValue: tab)
    }

    public var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(Tab.general)
            ReminderSettingsView(model: model)
                .tabItem { Label("提醒", systemImage: "bell") }
                .tag(Tab.reminders)
            SourceSettings(model: model)
                .tabItem { Label("数据来源", systemImage: "tray.2") }
                .tag(Tab.sources)
            RelaySettings(model: model)
                .tabItem { Label("AI 连接", systemImage: "cpu") }
                .tag(Tab.relay)
        }
        .frame(width: 500)
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }
}

private struct GeneralSettings: View {
    @Bindable var model: CalendarModel

    var body: some View {
        Form {
            Section {
                Toggle("登录 Mac 时自动打开 Daily", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.actions.setLaunchAtLogin($0) }
                ))
                Toggle("在菜单栏显示 Daily", isOn: $model.showMenuBarIcon)
            } footer: {
                Text("自动打开时只在后台运行，不弹出主窗口，日程、小组件和提醒保持最新。关掉主窗口后 Daily 也会留在菜单栏里。")
                    .foregroundStyle(.secondary)
            }
            Section("显示") {
                Picker("字体大小", selection: $model.textScale) {
                    ForEach(TextScale.steps, id: \.self) { step in
                        Text(Self.scaleName(step)).tag(step)
                    }
                }
                Picker("时间轴从几点开始", selection: $model.timelineDefaultHour) {
                    ForEach(0...12, id: \.self) { Text("\($0):00").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }

    static func scaleName(_ step: CGFloat) -> String {
        switch step {
        case ..<1.05: "小"
        case ..<1.2: "标准"
        case ..<1.35: "大"
        case ..<1.5: "更大"
        default: "特大"
        }
    }
}

private struct ReminderSettingsView: View {
    @Bindable var model: CalendarModel

    private let leadOptions = [0, 30, 60, 90, 120, 180]
    private let dayOptions = [0, 1, 2, 3, 7]

    var body: some View {
        Form {
            Section {
                switch model.notificationAccess {
                case .granted:
                    Label("通知已开启", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .notDetermined:
                    HStack {
                        Text("还没有允许 Daily 发通知")
                        Spacer()
                        Button("允许通知") { model.actions.requestNotificationAccess() }
                    }
                case .denied:
                    HStack {
                        Text("通知被关闭了，提醒不会弹出")
                        Spacer()
                        Button("打开系统设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } footer: {
                HStack {
                    Text("Daily 只提醒出行、取件码和订阅续费，其他日程不打扰你。").foregroundStyle(.secondary)
                    Spacer()
                    Button("发送测试通知") { model.actions.sendTestNotification() }
                        .controlSize(.small)
                        .disabled(model.notificationAccess != .granted)
                }
            }

            Section("出行（火车、航班，以及标为「交通出行」的日程）") {
                Picker("出发前提醒", selection: $model.reminderSettings.travelLeadMinutes) {
                    ForEach(leadOptions, id: \.self) { Text(Self.leadName($0)).tag($0) }
                }
                Toggle("前一天晚上提醒", isOn: $model.reminderSettings.travelEveningBefore)
                if model.reminderSettings.travelEveningBefore {
                    TimeOfDayPicker(title: "提醒时间", minute: $model.reminderSettings.travelEveningMinute)
                }
            }

            Section("取件码") {
                Toggle("收到取件码时通知", isOn: $model.reminderSettings.parcelOnArrival)
                Toggle("每天提醒还没取的快递", isOn: $model.reminderSettings.parcelDaily)
                if model.reminderSettings.parcelDaily {
                    TimeOfDayPicker(title: "提醒时间", minute: $model.reminderSettings.parcelDailyMinute)
                }
            }

            Section("订阅续费") {
                Toggle("续费前提醒", isOn: $model.reminderSettings.subscriptionEnabled)
                if model.reminderSettings.subscriptionEnabled {
                    Picker("提前", selection: $model.reminderSettings.subscriptionLeadDays) {
                        ForEach(dayOptions, id: \.self) { Text($0 == 0 ? "当天" : "\($0) 天").tag($0) }
                    }
                    TimeOfDayPicker(title: "提醒时间", minute: $model.reminderSettings.subscriptionMinute)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }

    static func leadName(_ minutes: Int) -> String {
        switch minutes {
        case 0: "不提醒"
        case ..<60: "\(minutes) 分钟"
        case let m where m % 60 == 0: "\(m / 60) 小时"
        default: "\(minutes / 60) 小时 \(minutes % 60) 分钟"
        }
    }
}

/// 选一天中的某个时刻，值是从零点起的分钟数。
private struct TimeOfDayPicker: View {
    let title: String
    @Binding var minute: Int

    var body: some View {
        DatePicker(title, selection: Binding(
            get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(Double(minute * 60)) },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        ), displayedComponents: .hourAndMinute)
    }
}

private struct SourceSettings: View {
    @Bindable var model: CalendarModel
    @State private var courseURL = Preferences.shared.courseSiteURL
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("系统日历") {
                switch model.calendarAccess {
                case .granted:
                    LabeledContent("已授权", value: "\(model.systemCalendars.count) 个日历，在侧边栏里逐个开关")
                case .notDetermined:
                    Button("允许读取系统日历") { model.actions.requestCalendarAccess() }
                case .denied:
                    Button("在系统设置中允许访问日历") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            Section("教务课程") {
                TextField("教务系统网址", text: $courseURL)
                    .onSubmit { Preferences.shared.courseSiteURL = courseURL }
                    .onChange(of: courseURL) { Preferences.shared.courseSiteURL = courseURL }
                LabeledContent("课表") {
                    HStack {
                        Text(model.courseSchedule.map { "\($0.semester ?? "已导入") · \(Set($0.courses.map(\.name)).count) 门课" } ?? "未导入")
                            .foregroundStyle(.secondary)
                        Button(model.courseSchedule == nil ? "导入…" : "重新导入…") { showInMainWindow { model.showingCourseImport = true } }
                    }
                }
            }
            Section("订阅") {
                LabeledContent("在订") {
                    HStack {
                        Text("\(model.subscriptions.filter(\.isActive).count) 项").foregroundStyle(.secondary)
                        Button("管理订阅…") { showInMainWindow { model.showingSubscriptions = true } }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }

    /// 导入课表、订阅管理都是主窗口里的表单：先把主窗口打开到前面。
    private func showInMainWindow(_ action: @escaping @MainActor () -> Void) {
        openWindow(id: "main")
        NSApp.activate()
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            action()
        }
    }
}

private struct RelaySettings: View {
    @Bindable var model: CalendarModel
    @State private var newURL = ""
    @State private var invalid = false
    @State private var publicHost = Preferences.shared.relayPublicHost ?? ""

    var body: some View {
        Form {
            Section {
                if let relay = model.relay {
                    LabeledContent("状态") {
                        HStack(spacing: 6) {
                            Circle().fill(relay.error == nil ? Color.green : Color.orange).frame(width: 7, height: 7)
                            Text(relay.error ?? (relay.isLive ? "已连接 · 实时" : "已连接"))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("立即同步") { model.actions.syncRelay() }
                        Button("断开", role: .destructive) { model.actions.disconnectRelay() }
                    }
                } else {
                    Text("未连接。连接后 Grok、Muse 可以读写日程，短信取件码和车票也会经它进来。").foregroundStyle(.secondary)
                }
            } header: {
                Text("中转服务")
            }
            Section {
                SecureField("中转服务地址", text: $newURL, prompt: Text("https://…/密钥"))
                HStack {
                    if invalid { Text("地址格式不对").foregroundStyle(.red) }
                    Spacer()
                    Button(model.relay == nil ? "连接" : "换成这个地址") {
                        invalid = !model.actions.connectRelay(newURL.trimmingCharacters(in: .whitespacesAndNewlines))
                        if !invalid { newURL = "" }
                    }
                    .disabled(newURL.isEmpty)
                }
            } header: {
                Text(model.relay == nil ? "连接" : "更换地址")
            } footer: {
                Text("地址里含密钥，保存在钥匙串里，不会显示出来。").foregroundStyle(.secondary)
            }
            Section {
                TextField("手机直连域名", text: $publicHost, prompt: Text("如 daily.example.com，可不填"))
                    .onSubmit { apply() }
                HStack {
                    Spacer()
                    Button("应用") { apply() }
                        .disabled(publicHost == (Preferences.shared.relayPublicHost ?? ""))
                }
            } header: {
                Text("手机直连")
            } footer: {
                Text("iPhone 快捷指令和日历订阅走这个域名（国内访问 workers.dev 不稳定时用）。").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
    }

    private func apply() {
        let host = publicHost.trimmingCharacters(in: .whitespaces)
        model.actions.setRelayPublicHost(host.isEmpty ? nil : host)
    }
}
