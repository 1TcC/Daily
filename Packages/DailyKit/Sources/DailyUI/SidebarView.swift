import DailyKit
import SwiftUI

/// 左侧边栏：迷你月历、待确认入口、按来源筛选、同步状态。
struct SidebarView: View {
    @Environment(\.uiScale) private var scale
    @Bindable var model: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 日历多时可以滚动，同步状态固定在底部。
            ScrollView(.vertical) {
                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
            }
            .scrollIndicators(.never)
            VStack(alignment: .leading, spacing: 4) {
                StatusLine(text: model.lastSync.map { "全部来源已同步 · \($0.formatted("H:mm"))" } ?? "尚未同步")
                if let error = model.loadError {
                    Text(error).scaledFont(10).foregroundStyle(.red).lineLimit(2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            MiniMonthView(model: model)

            if !model.pending.isEmpty {
                Button { model.showingInbox = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "tray.full")
                        Text("待确认")
                        Spacer()
                        Text("\(model.pending.count)")
                            .scaledFont(11, weight: .semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(SourceKind.message.color))
                    }
                    .scaledFont(13)
                    .padding(.horizontal, 8)
                    .frame(height: 30 * scale)
                    .background(RoundedRectangle(cornerRadius: 7).fill(SourceKind.message.tint))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("数据来源")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                ForEach(SourceKind.allCases, id: \.self) { kind in
                    SourceRow(kind: kind, count: model.count(of: kind), isOn: !model.hiddenKinds.contains(kind)) {
                        model.toggle(kind)
                    }
                    if kind == .systemCalendar {
                        SystemCalendarList(model: model)
                    }
                    if kind == .course {
                        CourseImportEntry(model: model)
                    }
                    if kind == .agent {
                        GrokRelayEntry(model: model)
                    }
                }
            }
        }
    }
}

/// 「系统日历」下面的子列表：未授权时给出授权入口，授权后按账户列出每个日历，可单独开关。
private struct SystemCalendarList: View {
    @Environment(\.uiScale) private var scale
    @Bindable var model: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch model.calendarAccess {
            case .notDetermined:
                hint("允许读取系统日历", systemImage: "lock.open") { model.actions.requestCalendarAccess() }
            case .denied:
                hint("在系统设置中允许访问日历", systemImage: "gearshape") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .granted:
                if !model.systemCalendars.isEmpty {
                    Button {
                        model.systemCalendarsExpanded.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: model.systemCalendarsExpanded ? "chevron.down" : "chevron.right")
                                .scaledFont(9, weight: .semibold)
                            Text("\(model.systemCalendars.count) 个日历")
                        }
                        .scaledFont(11)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 29)
                    .frame(height: 20 * scale)
                }
                if model.systemCalendarsExpanded {
                    ForEach(model.calendarsByAccount, id: \.account) { group in
                        Text(group.account)
                            .scaledFont(10, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 29)
                            .padding(.top, 4)
                        ForEach(group.calendars) { cal in
                            CalendarToggleRow(calendar: cal, isOn: !model.excludedCalendarIDs.contains(cal.id)) {
                                model.setCalendar(cal.id, included: model.excludedCalendarIDs.contains(cal.id))
                            }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func hint(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .scaledFont(11)
                .foregroundStyle(SourceKind.systemCalendar.color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 29)
        .frame(height: 22 * scale)
    }
}

/// 「Agent / Bot 写入」下面：AI 连接状态，复制各个 AI 的连接器地址（地址里带密钥，不在界面上明文显示）。
private struct GrokRelayEntry: View {
    let model: CalendarModel
    @Environment(\.uiScale) private var scale
    @State private var copied: String?

    /// 已接入的 AI：显示名和连接器路径里的名字。
    private let clients = [("Grok", "grok"), ("Muse", "muse")]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let relay = model.relay {
                HStack(spacing: 5) {
                    Circle().fill(relay.error == nil ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(relay.error ?? "AI 已连接 · " + (relay.isLive ? "实时" : relay.lastSync.map { "\($0.formatted("H:mm")) 同步" } ?? "连接中"))
                        .lineLimit(2)
                }
                .scaledFont(11)
                .foregroundStyle(.secondary)
                ForEach(clients, id: \.1) { name, client in
                    Button {
                        let url = client == "grok" ? relay.mcpURL : relay.mcpURL.appendingPathComponent(client)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        copied = client
                        Task { try? await Task.sleep(for: .seconds(2)); if copied == client { copied = nil } }
                    } label: {
                        Label(copied == client ? "已复制" : "复制 \(name) 连接器地址",
                              systemImage: copied == client ? "checkmark" : "doc.on.doc")
                            .scaledFont(11)
                            .foregroundStyle(SourceKind.agent.color)
                    }
                    .buttonStyle(.plain)
                    .help("粘贴到 \(name) 的自定义 MCP 连接器里。地址里含密钥，不要发给别人。")
                }
            } else {
                Text("未连接 AI 助手").scaledFont(11).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 29)
        .padding(.vertical, 2)
        .contextMenu {
            if model.relay != nil {
                Button("立即同步") { model.actions.syncRelay() }
                Button("断开 AI 助手", role: .destructive) { model.actions.disconnectRelay() }
            }
        }
    }
}

/// 「教务课程」下面：已导入课表的摘要，以及导入 / 重新导入的入口。
private struct CourseImportEntry: View {
    let model: CalendarModel
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button { model.showingCourseImport = true } label: {
            HStack(spacing: 4) {
                Image(systemName: model.courseSchedule == nil ? "square.and.arrow.down" : "arrow.triangle.2.circlepath")
                Text(label).lineLimit(1)
            }
            .scaledFont(11)
            .foregroundStyle(SourceKind.course.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 29)
        .frame(height: 22 * scale)
        .help("在 App 内登录教务系统并导入课表")
    }

    private var label: String {
        guard let schedule = model.courseSchedule else { return "从教务系统导入课表…" }
        let count = Set(schedule.courses.map(\.name)).count
        return "\(schedule.semester ?? "已导入") · \(count) 门课 · 重新导入"
    }
}

private struct CalendarToggleRow: View {
    @Environment(\.uiScale) private var scale
    let calendar: SystemCalendarInfo
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        let color = UInt32(calendar.colorHex.dropFirst(), radix: 16).map { Color(nsColor: NSColor(hex: $0)) }
            ?? SourceKind.systemCalendar.color
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isOn ? color : .clear)
                    .strokeBorder(color, lineWidth: isOn ? 0 : 1.5)
                    .frame(width: 9 * scale, height: 9 * scale)
                Text(calendar.title)
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .lineLimit(1)
                Spacer()
            }
            .scaledFont(12)
            .padding(.leading, 31)
            .frame(height: 22 * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct SourceRow: View {
    @Environment(\.uiScale) private var scale
    let kind: SourceKind
    let count: Int
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isOn ? kind.color : .clear)
                    .strokeBorder(kind.color, lineWidth: isOn ? 0 : 1.5)
                    .frame(width: 14 * scale, height: 14 * scale)
                    .overlay {
                        if isOn {
                            Image(systemName: "checkmark")
                                .scaledFont(8, weight: .heavy)
                                .foregroundStyle(.white)
                        }
                    }
                Text(kind.displayName)
                Spacer()
                if count > 0 {
                    Text("\(count)").foregroundStyle(.secondary).scaledFont(12)
                }
            }
            .scaledFont(13)
            .padding(.horizontal, 6)
            .frame(height: 26 * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct StatusLine: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
            Text(text)
        }
        .scaledFont(11)
        .foregroundStyle(.secondary)
    }
}

struct MiniMonthView: View {
    @Environment(\.uiScale) private var scale
    @Bindable var model: CalendarModel

    var body: some View {
        let cal = model.calendar
        let days = model.monthGridDays(for: model.anchorDate)
        let month = cal.component(.month, from: model.anchorDate)
        let week = Set(model.mode == .week ? model.visibleDays.map { cal.startOfDay(for: $0) } : [])
        VStack(alignment: .leading, spacing: 8) {
            Text(model.anchorDate.formatted("yyyy年M月", calendar: cal))
                .scaledFont(13, weight: .semibold)
                .padding(.leading, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                    Text($0).scaledFont(11).foregroundStyle(.secondary).frame(height: 20 * scale)
                }
                ForEach(days, id: \.self) { day in
                    let today = model.isToday(day)
                    let inMonth = cal.component(.month, from: day) == month
                    Button { model.anchorDate = day } label: {
                        Text("\(cal.component(.day, from: day))")
                            .scaledFont(12, weight: today ? .semibold : .regular)
                            .foregroundStyle(today ? .white : (inMonth ? .primary : .secondary))
                            .frame(width: 22 * scale, height: 22 * scale)
                            .background(Circle().fill(today ? Palette.today : .clear))
                            .frame(maxWidth: .infinity, minHeight: 26 * scale)
                            .background(week.contains(cal.startOfDay(for: day)) ? Palette.weekRow : .clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
