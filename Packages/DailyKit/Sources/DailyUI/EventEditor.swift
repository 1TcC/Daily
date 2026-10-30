import DailyKit
import SwiftUI

/// 编辑表单里的日程：新建或修改手动日程。
public struct EventDraft: Identifiable, Sendable {
    public var id: UUID
    public var isNew: Bool
    /// 我的日程，或交通出行（会按出行提醒）。
    public var kind: SourceKind
    public var title = ""
    public var location = ""
    public var notes = ""
    public var isAllDay = false
    public var start: Date
    public var end: Date
    /// 出行才有：座位、检票口 / 登机口。
    public var seat = ""
    public var gate = ""
    private var metadata: [String: String] = [:]

    public init(start: Date, calendar: Calendar) {
        id = UUID()
        isNew = true
        kind = .manual
        self.start = start
        end = start.addingTimeInterval(3600)
    }

    public init(item: CalendarItem, calendar: Calendar) {
        id = item.id
        isNew = false
        kind = item.sourceKind == .travel ? .travel : .manual
        title = item.title
        location = item.location ?? ""
        notes = item.notes ?? ""
        isAllDay = item.isAllDay
        start = item.start
        // 全天日程存的是「次日零点」，表单里显示最后一天
        end = item.isAllDay ? (calendar.date(byAdding: .day, value: -1, to: item.effectiveEnd) ?? item.start)
            : (item.end ?? item.start.addingTimeInterval(3600))
        seat = item.metadata["seat"] ?? ""
        gate = item.metadata["gate"] ?? ""
        metadata = item.metadata
    }

    public var isValid: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && end >= start }

    public func item(calendar: Calendar) -> CalendarItem {
        var metadata = metadata
        for (key, value) in [("seat", seat), ("gate", gate)] {
            let value = value.trimmingCharacters(in: .whitespaces)
            metadata[key] = kind == .travel && !value.isEmpty ? value : nil
        }
        let start = isAllDay ? calendar.startOfDay(for: start) : start
        let end = isAllDay ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))! : end
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return CalendarItem(
            id: id, sourceKind: kind, sourceID: CalendarItem.manualSourceID,
            title: title.trimmingCharacters(in: .whitespaces), notes: clean(notes), location: clean(location),
            start: start, end: max(end, start), isAllDay: isAllDay, metadata: metadata
        )
    }
}

/// 新建 / 编辑日程的表单。
public struct EventEditorView: View {
    let model: CalendarModel
    @State var draft: EventDraft
    @State private var confirmingDelete = false

    public init(model: CalendarModel, draft: EventDraft) {
        self.model = model
        _draft = State(initialValue: draft)
    }

    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("标题", text: $draft.title, prompt: Text("日程名称"))
                        .focused($titleFocused)
                    Picker("类别", selection: $draft.kind) {
                        Text("我的日程").tag(SourceKind.manual)
                        Text("交通出行").tag(SourceKind.travel)
                    }
                    .pickerStyle(.segmented)
                    TextField("地点", text: $draft.location, prompt: Text(draft.kind == .travel ? "出发站 / 机场" : "可选"))
                }
                Section {
                    Toggle("全天", isOn: $draft.isAllDay)
                    DatePicker("开始", selection: $draft.start,
                               displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                        .onChange(of: draft.start) { old, new in
                            // 改开始时间时保持时长不变
                            draft.end = draft.end.addingTimeInterval(new.timeIntervalSince(old))
                        }
                    DatePicker("结束", selection: $draft.end, in: draft.start...,
                               displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                }
                if draft.kind == .travel {
                    Section {
                        TextField("座位", text: $draft.seat, prompt: Text("如 5车12号"))
                        TextField("检票口 / 登机口", text: $draft.gate, prompt: Text("如 B12"))
                    } footer: {
                        Text("出行会按「设置 → 提醒」在出发前提醒你。").foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("备注", text: $draft.notes, prompt: Text("可选"), axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .formStyle(.grouped)
            .environment(\.locale, Locale(identifier: "zh_CN"))

            HStack {
                if !draft.isNew {
                    Button("删除", role: .destructive) { confirmingDelete = true }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "添加" : "保存") { model.save(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
            .padding(16)
        }
        .frame(width: 420)
        .onAppear { titleFocused = draft.isNew }
        .confirmationDialog("删除这个日程？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) {
                if let item = try? model.store.item(id: draft.id) { model.delete(item) }
                dismiss()
            }
        }
    }
}
