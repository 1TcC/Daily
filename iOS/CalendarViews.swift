import DailyKit
import DailyUI
import SwiftUI

/// 仿 iOS「日历」：打开是月视图，点某天进入带周条的时间轴，左上角返回月份。
struct PhoneCalendarView: View {
    let services: PhoneServices
    @State private var path: [Route] = []
    @State private var selectedDay = Calendar.mondayFirst.startOfDay(for: .now)
    /// 月视图滚动到的月份（当月 1 号）。
    @State private var month: Date? = Calendar.mondayFirst.date(from: Calendar.mondayFirst.dateComponents([.year, .month], from: .now))
    @State private var sheet: Sheet?
    @State private var selectedItem: CalendarItem?

    enum Route: Hashable { case day, list }

    enum Sheet: String, Identifiable {
        case add, parcels, settings
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            MonthScreen(services: services, month: $month) { day in
                selectedDay = day
                path = [.day]
            }
            .toolbar { topBar(year: true) }
            .navigationDestination(for: Route.self) { route in
                Group {
                    switch route {
                    case .day:
                        DayScreen(services: services, selectedDay: $selectedDay) { selectedItem = $0 }
                    case .list:
                        AgendaView(services: services) { selectedItem = $0 }
                    }
                }
                .navigationBarBackButtonHidden()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            // 返回到正在看的那一天所在的月份
                            month = monthStart(selectedDay)
                            path = []
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "chevron.left")
                                Text(selectedDay.formatted("M月", calendar: services.calendar)).fixedSize()
                            }
                        }
                    }
                    topBar(year: false)
                }
                .toolbar { bottomBar }
            }
            .toolbar { bottomBar }
        }
        .tint(.red)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add: AddEventView(services: services, start: defaultStart)
            case .parcels: ParcelsView(services: services)
            case .settings: PhoneSettingsView(services: services)
            }
        }
        .sheet(item: $selectedItem) { item in
            ScrollView { EventDetailView(item: item, calendar: services.calendar) }
                .environment(\.markParcelPicked, { services.markPicked($0) })
                .presentationDetents([.medium, .large])
        }
        #if DEBUG
        .onAppear {
            // 模拟器截图用：-dailyScreen day / list
            switch UserDefaults.standard.string(forKey: "dailyScreen") {
            case "day": path = [.day]
            case "list": path = [.list]
            default: break
            }
        }
        #endif
    }

    private func monthStart(_ date: Date) -> Date {
        let cal = services.calendar
        return cal.date(from: cal.dateComponents([.year, .month], from: date))!
    }

    /// 新建日程默认从选中那天开始：今天取下一个整点，别的日子取 9 点。
    private var defaultStart: Date {
        let cal = services.calendar
        if path.isEmpty || cal.isDateInToday(selectedDay) {
            return cal.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
        }
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: selectedDay) ?? selectedDay
    }

    @ToolbarContentBuilder
    private func topBar(year: Bool) -> some ToolbarContent {
        if year {
            ToolbarItem(placement: .topBarLeading) {
                Text((month ?? .now).formatted("yyyy年", calendar: services.calendar))
                    .font(.headline)
                    .foregroundStyle(.red)
                    .fixedSize()
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if path != [.list] {
                Button { path = [.list] } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("列表")
            } else {
                Button { path = [.day] } label: { Image(systemName: "calendar.day.timeline.left") }
                    .accessibilityLabel("时间轴")
            }
            Button { sheet = .add } label: { Image(systemName: "plus") }
                .accessibilityLabel("新建日程")
        }
    }

    /// 底部和系统日历一样：今天、中间的收件箱（这里是待取件）、右边设置。
    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button("今天") {
                let today = services.calendar.startOfDay(for: .now)
                selectedDay = today
                withAnimation { month = monthStart(today) }
            }
            Spacer()
            Button(services.pendingParcels.isEmpty ? "待取件" : "待取件 \(services.pendingParcels.count)") { sheet = .parcels }
            Spacer()
            Button("设置") { sheet = .settings }
        }
    }
}

// MARK: - 月视图

/// 上下滚动的月份：星期固定在顶部，每天列出日程名称，像系统日历的「详细」样式。
private struct MonthScreen: View {
    let services: PhoneServices
    @Binding var month: Date?
    let onSelect: (Date) -> Void

    private var cal: Calendar { services.calendar }
    /// 前 6 个月到后 12 个月。
    private var months: [Date] {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: .now))!
        return (-6...12).compactMap { cal.date(byAdding: .month, value: $0, to: first) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { name in
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(name == "六" || name == "日" ? .secondary : .primary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(months, id: \.self) { month in
                        MonthGrid(services: services, month: month, onSelect: onSelect)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $month, anchor: .top)
            .scrollIndicators(.hidden)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MonthGrid: View {
    let services: PhoneServices
    let month: Date
    let onSelect: (Date) -> Void

    private var cal: Calendar { services.calendar }

    /// 这个月的格子：每周 7 格，月初前和月末后的留空。
    private var weeks: [[Date?]] {
        let range = cal.range(of: .day, in: .month, for: month)!
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        cells += range.map { cal.date(byAdding: .day, value: $0 - 1, to: month) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<($0 + 7)]) }
    }

    var body: some View {
        let isCurrent = cal.isDate(month, equalTo: .now, toGranularity: .month)
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        VStack(spacing: 0) {
            // 月份标题对齐到 1 号那一列
            GeometryReader { geo in
                Text(month.formatted("M月", calendar: cal))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(isCurrent ? Color.red : .primary)
                    .fixedSize()
                    .offset(x: geo.size.width / 7 * CGFloat(lead) + 6)
            }
            .frame(height: 38)
            ForEach(weeks.indices, id: \.self) { index in
                VStack(spacing: 0) {
                    Divider()
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<7, id: \.self) { column in
                            if let day = weeks[index][column] {
                                DayCell(day: day, items: services.items(on: day), calendar: cal)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onSelect(day) }
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .frame(height: 96)
            }
        }
        .padding(.bottom, 10)
    }
}

private struct DayCell: View {
    let day: Date
    let items: [CalendarItem]
    let calendar: Calendar

    var body: some View {
        let today = calendar.isDateInToday(day)
        let weekend = calendar.isDateInWeekend(day)
        VStack(spacing: 1) {
            ZStack {
                if today { Circle().fill(Color.red).frame(width: 25, height: 25) }
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 15, weight: today ? .semibold : .regular))
                    .foregroundStyle(today ? .white : (weekend ? .secondary : .primary))
            }
            .frame(height: 25)
            Text(Lunar.dayText(day))
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 10)
            VStack(spacing: 1) {
                ForEach(items.prefix(3)) { item in
                    Text(item.title)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(item.displayColor)
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, minHeight: 12, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 2).fill(item.displayColor.opacity(0.16)))
                }
                if items.count > 3 {
                    Text("+\(items.count - 3)")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }
}

// MARK: - 日视图

/// 顶部周条可左右滑动换周，下面的时间轴左右滑动换天，和系统日历一样。
private struct DayScreen: View {
    let services: PhoneServices
    @Binding var selectedDay: Date
    let onOpen: (CalendarItem) -> Void

    private var cal: Calendar { services.calendar }
    /// 可翻的范围：今天前后。
    private var base: Date { cal.date(byAdding: .day, value: -180, to: cal.startOfDay(for: .now))! }
    private let dayCount = 540

    private var dayIndex: Binding<Int> {
        Binding(
            get: { cal.dateComponents([.day], from: base, to: selectedDay).day ?? 0 },
            set: { selectedDay = cal.date(byAdding: .day, value: $0, to: base) ?? selectedDay }
        )
    }

    private var weekIndex: Binding<Int> {
        Binding(
            get: { (cal.dateComponents([.day], from: firstWeek, to: selectedDay).day ?? 0) / 7 },
            set: { week in
                // 换周时保持星期几不变
                let offset = (cal.dateComponents([.day], from: firstWeek, to: selectedDay).day ?? 0) % 7
                selectedDay = cal.date(byAdding: .day, value: week * 7 + offset, to: firstWeek) ?? selectedDay
            }
        )
    }

    private var firstWeek: Date { cal.startOfWeek(for: base) }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: weekIndex) {
                ForEach(0..<(dayCount / 7 + 1), id: \.self) { week in
                    WeekStrip(week: cal.date(byAdding: .day, value: week * 7, to: firstWeek)!, selected: selectedDay,
                              calendar: cal) { selectedDay = $0 }
                        .tag(week)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 58)

            Text("\(selectedDay.formatted("yyyy年M月d日 EEEE", calendar: cal))  \(Lunar.dayText(selectedDay))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            Divider()

            TabView(selection: dayIndex) {
                ForEach(0..<dayCount, id: \.self) { index in
                    let day = cal.date(byAdding: .day, value: index, to: base)!
                    DayTimeline(day: day, items: services.items(on: day), calendar: cal, onOpen: onOpen)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WeekStrip: View {
    let week: Date
    let selected: Date
    let calendar: Calendar
    let onSelect: (Date) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: week)!
                let isToday = calendar.isDateInToday(day)
                let isSelected = calendar.isDate(day, inSameDayAs: selected)
                VStack(spacing: 3) {
                    Text(day.formatted("EEEEE", calendar: calendar))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : (isToday ? Color.red : Color.primary))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(isSelected ? (isToday ? Color.red : Color.primary) : .clear))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(day) }
            }
        }
    }
}

/// 一天的时间轴：全天日程在上面，下面 0–24 点，重叠的日程并排，今天有红色的当前时间线。
private struct DayTimeline: View {
    let day: Date
    let items: [CalendarItem]
    let calendar: Calendar
    let onOpen: (CalendarItem) -> Void

    private let hourHeight: CGFloat = 54
    private let gutter: CGFloat = 52

    private var dayStart: Date { calendar.startOfDay(for: day) }
    private var timed: [CalendarItem] { items.filter { !$0.isAllDay } }
    private var allDay: [CalendarItem] { items.filter(\.isAllDay) }

    /// 打开时先看到哪个钟点：今天是现在，其他天是第一个日程，都没有就 7 点。
    private var initialHour: Int {
        if calendar.isDateInToday(day) { return max(calendar.component(.hour, from: .now) - 1, 0) }
        let first = timed.filter { calendar.isDate($0.start, inSameDayAs: day) }.map { calendar.component(.hour, from: $0.start) }.min()
        return min(first ?? 7, 7)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !allDay.isEmpty {
                VStack(spacing: 2) {
                    ForEach(allDay) { item in
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(item.displayColor)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 4).fill(item.displayColor.opacity(0.16)))
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(item) }
                    }
                }
                .padding(.leading, gutter)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        hours
                        GeometryReader { geo in
                            let width = geo.size.width - gutter - 8
                            ForEach(DayLayout.layout(timed)) { placed in
                                let frame = frame(for: placed, width: width)
                                TimelineEvent(item: placed.item, height: frame.height, calendar: calendar)
                                    .frame(width: frame.width, height: frame.height)
                                    .offset(x: gutter + frame.minX, y: frame.minY)
                                    .onTapGesture { onOpen(placed.item) }
                            }
                        }
                        if calendar.isDateInToday(day) { nowLine }
                    }
                    .frame(height: hourHeight * 24 + 16)
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(initialHour, anchor: .top) }
            }
        }
    }

    private var hours: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 6) {
                    Text(hour == 0 || hidesLabel(hour) ? "" : "\(hour):00")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: gutter - 8, alignment: .trailing)
                        .offset(y: -7)
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 0.5)
                }
                .frame(height: hourHeight, alignment: .top)
                .id(hour)
            }
        }
        .padding(.top, 8)
    }

    /// 红线上的当前时间离整点太近时，让开那个刻度。
    private func hidesLabel(_ hour: Int) -> Bool {
        guard calendar.isDateInToday(day) else { return false }
        let minutes = Date.now.timeIntervalSince(dayStart) / 60
        return abs(minutes - Double(hour * 60)) < 12
    }

    private var nowLine: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 0) {
                Text(context.date.formatted("H:mm", calendar: calendar))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.red)
                    .frame(width: gutter - 6, alignment: .trailing)
                    .padding(.trailing, 2)
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Rectangle().fill(Color.red).frame(height: 1.5)
            }
            .offset(y: y(context.date) - 7)
        }
    }

    private func y(_ date: Date) -> CGFloat {
        8 + CGFloat(date.timeIntervalSince(dayStart) / 3600) * hourHeight
    }

    private func frame(for placed: PositionedItem, width: CGFloat) -> CGRect {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let start = max(placed.item.start, dayStart)
        let end = min(max(placed.item.effectiveEnd, placed.item.start.addingTimeInterval(DayLayout.minimumVisualDuration)), dayEnd)
        let top = y(start) + 1
        let gap: CGFloat = placed.x + placed.width < 0.999 ? 2 : 0
        return CGRect(x: width * placed.x, y: top, width: width * placed.width - gap, height: max(24, y(end) - top - 1))
    }
}

private struct TimelineEvent: View {
    let item: CalendarItem
    let height: CGFloat
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title).font(.footnote.weight(.semibold)).lineLimit(height < 44 ? 1 : 2)
            if height >= 44 {
                Text([item.timeText(calendar: calendar), item.location].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .opacity(0.85)
                    .lineLimit(height < 70 ? 1 : 2)
            }
        }
        .foregroundStyle(item.displayColor)
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(item.displayColor.opacity(0.16))
                RoundedRectangle(cornerRadius: 1.5).fill(item.displayColor).frame(width: 3).padding(.vertical, 3).padding(.leading, 2)
            }
        }
        .contentShape(Rectangle())
    }
}
