import DailyKit
import DailyUI
import SwiftUI

/// iPhone 版设置：连接、本机日历、提醒。
struct PhoneSettingsView: View {
    @Bindable var services: PhoneServices
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private let leadOptions = [0, 30, 60, 90, 120, 180]
    private let dayOptions = [0, 1, 2, 3, 7]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("状态") {
                        HStack(spacing: 6) {
                            Circle().fill(services.error == nil ? Color.green : Color.orange).frame(width: 7, height: 7)
                            Text(statusText).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    if let host = services.connection?.baseURL.host {
                        LabeledContent("服务器", value: host)
                    }
                    Button("立即同步") { Task { await services.syncNow() } }
                        .disabled(services.isSyncing)
                    Button("断开连接", role: .destructive) { services.disconnect() }
                } header: {
                    Text("Mac 上的 Daily")
                } footer: {
                    Text("课程、系统日历、订阅续费来自 Mac 上传的快照（Mac 开着 Daily 时更新）；短信取件码、车次和 AI 写入的日程直接从服务器同步。")
                }

                Section {
                    Toggle("读取 iPhone 上的日历", isOn: $services.usesLocalCalendar)
                    if services.usesLocalCalendar, services.calendarAccess == .denied {
                        Button("在设置中允许访问日历") { openSettings() }
                    }
                } footer: {
                    Text("打开后系统日历直接读本机（实时），不再用 Mac 同步来的那份。")
                }

                Section {
                    switch services.notificationAccess {
                    case .granted:
                        Label("通知已开启", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .notDetermined:
                        Button("允许通知") { Task { await services.requestNotifications() } }
                    case .denied:
                        Button("通知已关闭，去设置里打开") { openSettings() }
                    }
                } header: {
                    Text("提醒")
                } footer: {
                    Text("只提醒出行、取件码和订阅续费。Mac 上的 Daily 也会提醒，不需要的话可以在 Mac 的设置里关掉。")
                }

                Section("出行") {
                    Picker("出发前提醒", selection: $services.reminderSettings.travelLeadMinutes) {
                        ForEach(leadOptions, id: \.self) { Text(Self.leadName($0)).tag($0) }
                    }
                    Toggle("前一天晚上提醒", isOn: $services.reminderSettings.travelEveningBefore)
                    if services.reminderSettings.travelEveningBefore {
                        MinutePicker(title: "提醒时间", minute: $services.reminderSettings.travelEveningMinute)
                    }
                }
                Section("取件码") {
                    Toggle("收到取件码时通知", isOn: $services.reminderSettings.parcelOnArrival)
                    Toggle("每天提醒还没取的快递", isOn: $services.reminderSettings.parcelDaily)
                    if services.reminderSettings.parcelDaily {
                        MinutePicker(title: "提醒时间", minute: $services.reminderSettings.parcelDailyMinute)
                    }
                }
                Section("订阅续费") {
                    Toggle("续费前提醒", isOn: $services.reminderSettings.subscriptionEnabled)
                    if services.reminderSettings.subscriptionEnabled {
                        Picker("提前", selection: $services.reminderSettings.subscriptionLeadDays) {
                            ForEach(dayOptions, id: \.self) { Text($0 == 0 ? "当天" : "\($0) 天").tag($0) }
                        }
                        MinutePicker(title: "提醒时间", minute: $services.reminderSettings.subscriptionMinute)
                    }
                }
            }
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private var statusText: String {
        if let error = services.error { return error }
        if services.isSyncing { return "同步中…" }
        let synced = services.lastSync.map { "\($0.formatted("H:mm", calendar: services.calendar)) 已同步" } ?? "已连接"
        return services.isLive ? "实时 · \(synced)" : synced
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
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

/// 一天中的某个时刻，值是从零点起的分钟数。
private struct MinutePicker: View {
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
