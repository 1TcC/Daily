import DailyKit
import SwiftUI

public extension CalendarItem {
    /// 「13:30 – 15:05」；`compact` 时去掉空格，窄处更容易放下。
    func timeText(calendar: Calendar, compact: Bool = false) -> String {
        if isAllDay { return "全天" }
        let start = start.formatted("H:mm", calendar: calendar)
        guard let end else { return start }
        return start + (compact ? "-" : " – ") + end.formatted("H:mm", calendar: calendar)
    }
}

/// 点击日程后弹出的详情。
public struct EventDetailView: View {
    let item: CalendarItem
    let calendar: Calendar

    public init(item: CalendarItem, calendar: Calendar) {
        self.item = item
        self.calendar = calendar
    }
    @Environment(\.markParcelPicked) private var markParcelPicked
    @Environment(CalendarModel.self) private var model: CalendarModel?
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(item.displayColor).frame(width: 9, height: 9)
                Text(item.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                row("clock", "\(item.start.formatted("M月d日 EEE", calendar: calendar))  \(item.timeText(calendar: calendar))")
                if let location = item.location { row("mappin.and.ellipse", location) }
                if let teacher = item.metadata["teacher"] { row("person", teacher) }
                if let weeks = item.metadata["weeks"], !weeks.isEmpty {
                    row("calendar", [item.metadata["units"], weeks].compactMap { $0 }.joined(separator: " · "))
                }
                if let code = item.metadata["pickupCode"] { row("number", "取件码 \(code)") }
                if let seat = item.metadata["seat"] {
                    row("tram", [seat, item.metadata["gate"].map { "检票口 \($0)" }].compactMap { $0 }.joined(separator: " · "))
                }
                if let notes = item.notes, notes != item.metadata["teacher"] { row("text.alignleft", notes) }
                row(item.sourceKind.symbol, [item.sourceKind.displayName, item.metadata["calendarTitle"] ?? item.metadata["via"]]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            #if os(macOS)
            .font(.system(size: 12))
            #else
            .font(.subheadline)
            #endif
            if item.isParcelWithCode, let markParcelPicked {
                Button("标记为已取件") {
                    markParcelPicked(item)
                    dismiss()
                }
                .controlSize(.small)
            }
            if item.isEditable, let model {
                HStack {
                    Button("编辑…") {
                        dismiss()
                        model.edit(item)
                    }
                    Button("删除", role: .destructive) {
                        dismiss()
                        model.delete(item)
                    }
                }
                .controlSize(.small)
            }
        }
        #if os(macOS)
        .padding(14)
        .frame(width: 280, alignment: .leading)
        #else
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
        }
    }
}

struct AllDayChip: View {
    @Environment(\.uiScale) private var scale
    let item: CalendarItem

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(item.displayColor).frame(width: 6, height: 6)
            Text(item.title).lineLimit(1)
        }
        .scaledFont(11)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 22 * scale, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(item.displayTint))
    }
}
