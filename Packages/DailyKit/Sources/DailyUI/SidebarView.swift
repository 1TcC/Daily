import DailyKit
import SwiftUI

/// 左侧边栏：迷你月历、待确认入口、按来源筛选、同步状态。
struct SidebarView: View {
    @Bindable var model: CalendarModel

    var body: some View {
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
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                StatusLine(text: model.lastSync.map { "全部来源已同步 · \($0.formatted("H:mm"))" } ?? "尚未同步")
                if let error = model.loadError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
                }
            }
            .padding(.leading, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity, alignment: .top)
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
