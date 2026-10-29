import DailyKit
import SwiftUI

/// 左侧边栏：迷你月历、待确认入口、按来源筛选、同步状态。
struct SidebarView: View {
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
                    Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
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
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(SourceKind.message.color))
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(SourceKind.message.tint))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("数据来源")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                ForEach(SourceKind.allCases, id: \.self) { kind in
                    SourceRow(kind: kind, count: model.count(of: kind), isOn: !model.hiddenKinds.contains(kind)) {
                        model.toggle(kind)
                    }
                    if kind == .systemCalendar {
                        SystemCalendarList(model: model)
                    }
                }
            }
        }
    }
}

/// 「系统日历」下面的子列表：未授权时给出授权入口，授权后按账户列出每个日历，可单独开关。
private struct SystemCalendarList: View {
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
                                .font(.system(size: 9, weight: .semibold))
                            Text("\(model.systemCalendars.count) 个日历")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 29)
                    .frame(height: 20)
                }
                if model.systemCalendarsExpanded {
                    ForEach(model.calendarsByAccount, id: \.account) { group in
                        Text(group.account)
                            .font(.system(size: 10, weight: .semibold))
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
                .font(.system(size: 11))
                .foregroundStyle(SourceKind.systemCalendar.color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 29)
        .frame(height: 22)
    }
}

private struct CalendarToggleRow: View {
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
                    .frame(width: 9, height: 9)
                Text(calendar.title)
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .lineLimit(1)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.leading, 31)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct SourceRow: View {
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
                    .frame(width: 14, height: 14)
                    .overlay {
                        if isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                    }
                Text(kind.displayName)
                Spacer()
                if count > 0 {
                    Text("\(count)").foregroundStyle(.secondary).font(.system(size: 12))
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 6)
            .frame(height: 26)
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
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

struct MiniMonthView: View {
    @Bindable var model: CalendarModel

    var body: some View {
        let cal = model.calendar
        let days = model.monthGridDays(for: model.anchorDate)
        let month = cal.component(.month, from: model.anchorDate)
        let week = Set(model.mode == .week ? model.visibleDays.map { cal.startOfDay(for: $0) } : [])
        VStack(alignment: .leading, spacing: 8) {
            Text(model.anchorDate.formatted("yyyy年M月", calendar: cal))
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                    Text($0).font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 20)
                }
                ForEach(days, id: \.self) { day in
                    let today = model.isToday(day)
                    let inMonth = cal.component(.month, from: day) == month
                    Button { model.anchorDate = day } label: {
                        Text("\(cal.component(.day, from: day))")
                            .font(.system(size: 12, weight: today ? .semibold : .regular))
                            .foregroundStyle(today ? .white : (inMonth ? .primary : .secondary))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(today ? Palette.today : .clear))
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(week.contains(cal.startOfDay(for: day)) ? Palette.weekRow : .clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
