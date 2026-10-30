import DailyKit
import DailyUI
import SwiftUI

/// 日历的可翻范围：前后各 100 年，用懒加载，实际等于翻不到头。下标固定，翻页只算偏移。
enum CalendarRange {
    static let calendar = Calendar.mondayFirst
    static let today = calendar.startOfDay(for: .now)
    static let thisMonth = monthStart(today)
    static let thisYear = calendar.component(.year, from: today)
    static let years = Array((thisYear - 100)...(thisYear + 100))
    static let months: [Date] = (-1200...1200).compactMap { calendar.date(byAdding: .month, value: $0, to: thisMonth) }
    static let firstDay = calendar.date(byAdding: .day, value: -36525, to: today)!
    static let dayCount = 73050
    static let firstWeek = calendar.startOfWeek(for: firstDay)
    static let weekCount = dayCount / 7 + 1

    static func monthStart(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
    }
}

/// 月视图的样式，和系统日历一样三种。
enum MonthStyle: String, CaseIterable, Identifiable {
    case compact, stacked, details
    var id: Self { self }

    var title: String {
        switch self {
        case .compact: "紧凑"
        case .stacked: "叠放"
        case .details: "详细信息"
        }
    }

    var symbol: String {
        switch self {
        case .compact: "circle.grid.3x3"
        case .stacked: "square.grid.3x3.middle.filled"
        case .details: "rectangle.grid.1x2"
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .compact: 74
        case .stacked: 94
        case .details: 124
        }
    }
}

/// 仿 iOS「日历」的三层：年 → 月 → 日，左上角逐层返回。打开时在当前月份。
struct PhoneCalendarView: View {
    let services: PhoneServices
    @State private var path: [Route] = [.month]
    @State private var selectedDay = CalendarRange.today
    /// 月视图滚动到的月份（当月 1 号）。
    @State private var month: Date? = CalendarRange.thisMonth
    /// 年视图滚动到的年份。
    @State private var year: Int? = CalendarRange.thisYear
    @AppStorage("monthStyle") private var monthStyle = MonthStyle.details
    @State private var adding = false
    @State private var selectedItem: CalendarItem?

    enum Route: Hashable { case month, day, list }

    private var cal: Calendar { services.calendar }
    private var shownMonth: Date { month ?? CalendarRange.thisMonth }

    var body: some View {
        NavigationStack(path: $path) {
            YearScreen(services: services, year: $year) { picked in
                month = picked
                path = [.month]
            }
            .toolbar { trailingBar }
            .navigationDestination(for: Route.self) { route in
                destination(route)
                    .navigationBarBackButtonHidden()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { backButton(route) }
                        trailingBar
                    }
            }
        }
        // 工具栏用黑白色，红色只留给「今天」，和系统日历一样不刺眼
        .tint(.primary)
        .sheet(isPresented: $adding) { AddEventView(services: services, start: defaultStart).tint(.red) }
        .sheet(item: $selectedItem) { item in
            ScrollView { EventDetailView(item: item, calendar: cal) }
                .environment(\.markParcelPicked, { services.markPicked($0) })
                .presentationDetents([.medium, .large])
        }
        #if DEBUG
        .onAppear {
            // 模拟器截图用：-dailyScreen year / day / list
            switch UserDefaults.standard.string(forKey: "dailyScreen") {
            case "year": path = []
            case "day": path = [.month, .day]
            case "list": path = [.month, .list]
            default: break
            }
        }
        #endif
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .month:
            MonthScreen(services: services, month: $month, style: monthStyle) { day in
                selectedDay = day
                path = [.month, .day]
            }
        case .day:
            DayScreen(services: services, selectedDay: $selectedDay) { selectedItem = $0 }
        case .list:
            AgendaView(services: services) { selectedItem = $0 }
        }
    }

    /// 月视图返回到年，日视图和列表返回到月。
    private func backButton(_ route: Route) -> some View {
        Button {
            if route == .month {
                year = cal.component(.year, from: shownMonth)
                path = []
            } else {
                if route == .day { month = CalendarRange.monthStart(selectedDay) }
                path = [.month]
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                Text(route == .month ? shownMonth.formatted("yyyy年", calendar: cal)
                                     : (route == .day ? selectedDay : shownMonth).formatted("M月", calendar: cal))
                    .fixedSize()
            }
        }
    }

    /// 列表从正在看的地方开始：日视图是那一天，月视图是那个月（当月从今天）。
    private func showList() {
        let onDay = path.last == .day
        let thisMonth = CalendarRange.monthStart(.now) == shownMonth
        services.startDate = onDay ? selectedDay : (thisMonth ? cal.startOfDay(for: .now) : shownMonth)
        path = [.month, .list]
    }

    /// 新建日程默认从选中那天开始：今天取下一个整点，别的日子取 9 点。
    private var defaultStart: Date {
        if path.last != .day || cal.isDateInToday(selectedDay) {
            return cal.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
        }
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: selectedDay) ?? selectedDay
    }

    @ToolbarContentBuilder
    private var trailingBar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("今天") {
                let today = cal.startOfDay(for: .now)
                selectedDay = today
                withAnimation {
                    month = CalendarRange.monthStart(today)
                    year = cal.component(.year, from: today)
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if path.last == .list {
                Button { path = [.month, .day] } label: { Image(systemName: "calendar.day.timeline.left") }
                    .accessibilityLabel("时间轴")
            } else if path.last == .day {
                Button { showList() } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("列表")
            } else if !path.isEmpty {
                // 月视图：和系统日历一样在这里切换样式
                Menu {
                    Picker("月视图样式", selection: $monthStyle) {
                        ForEach(MonthStyle.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    Divider()
                    Button { showList() } label: { Label("列表", systemImage: "list.bullet") }
                } label: {
                    Image(systemName: monthStyle.symbol)
                }
                .accessibilityLabel("月视图样式")
            }
            Button { adding = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("新建日程")
        }
    }
}

// MARK: - 年视图

/// 上下滚动的年份，每年 12 个小月历；点某个月进入月视图。
private struct YearScreen: View {
    let services: PhoneServices
    @Binding var year: Int?
    let onPick: (Date) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(CalendarRange.years, id: \.self) { value in
                    YearGrid(year: value, calendar: services.calendar, onPick: onPick)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $year, anchor: .top)
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct YearGrid: View {
    let year: Int
    let calendar: Calendar
    let onPick: (Date) -> Void

    var body: some View {
        let current = year == calendar.component(.year, from: .now)
        VStack(alignment: .leading, spacing: 8) {
            Text("\(String(year))年")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(current ? Color.red : .primary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
            Divider()
            ForEach(0..<4, id: \.self) { row in
                HStack(alignment: .top, spacing: 14) {
                    ForEach(1...3, id: \.self) { column in
                        let month = calendar.date(from: DateComponents(year: year, month: row * 3 + column))!
                        MiniMonth(month: month, calendar: calendar)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(month) }
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.bottom, 16)
    }
}

/// 小月历：用 Canvas 画，滚动年份时不用创建几百个文字视图。
private struct MiniMonth: View {
    let month: Date
    let calendar: Calendar

    var body: some View {
        let current = calendar.isDate(month, equalTo: .now, toGranularity: .month)
        VStack(alignment: .leading, spacing: 3) {
            Text("\(calendar.component(.month, from: month))月")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(current ? Color.red : .primary)
            Canvas { context, size in
                let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
                let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
                let todayNumber = current ? calendar.component(.day, from: .now) : 0
                let w = size.width / 7, h = size.height / 6
                for day in 1...days {
                    let index = lead + day - 1
                    let center = CGPoint(x: w * (CGFloat(index % 7) + 0.5), y: h * (CGFloat(index / 7) + 0.5))
                    if day == todayNumber {
                        let r = min(w, h) * 0.55
                        context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                                     with: .color(.red))
                    }
                    context.draw(Text("\(day)").font(.system(size: 9, weight: day == todayNumber ? .semibold : .regular))
                        .foregroundColor(day == todayNumber ? .white : .primary), at: center)
                }
            }
            .frame(height: 78)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 月视图

/// 上下滚动的月份：星期固定在顶部，每天列出日程名称，像系统日历的「详细」样式。
private struct MonthScreen: View {
    let services: PhoneServices
    @Binding var month: Date?
    let style: MonthStyle
    let onSelect: (Date) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { name in
                    Text(name)
                        .font(.footnote)
                        .foregroundStyle(name == "六" || name == "日" ? .secondary : .primary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(CalendarRange.months, id: \.self) { month in
                        MonthGrid(services: services, month: month, style: style, onSelect: onSelect)
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
    let style: MonthStyle
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
                                DayCell(day: day, items: services.items(on: day), calendar: cal, style: style)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onSelect(day) }
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .frame(height: style.rowHeight)
            }
        }
        .padding(.bottom, 10)
    }
}

private struct DayCell: View {
    let day: Date
    let items: [CalendarItem]
    let calendar: Calendar
    let style: MonthStyle
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let today = calendar.isDateInToday(day)
        let weekend = calendar.isDateInWeekend(day)
        VStack(spacing: 1) {
            ZStack {
                if today { Circle().fill(Color.red).frame(width: 30, height: 30) }
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 18, weight: today ? .semibold : .regular))
                    .foregroundStyle(today ? .white : (weekend ? .secondary : .primary))
            }
            .frame(height: 30)
            Text(Lunar.dayText(day))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 13)
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .compact:
            // 紧凑：有安排就显示一个小圆点
            if !items.isEmpty {
                Circle().fill(Color.secondary).frame(width: 6, height: 6).padding(.top, 3)
            }
        case .stacked:
            // 叠放：每项一条色带，不写字
            VStack(spacing: 2) {
                ForEach(items.prefix(4)) { item in
                    RoundedRectangle(cornerRadius: 2).fill(item.eventBar(scheme)).frame(height: 7)
                }
            }
            .padding(.horizontal, 5)
            .padding(.top, 2)
        case .details:
            // 详细信息：写出日程名称
            VStack(spacing: 2) {
                ForEach(items.prefix(3)) { item in
                    // 放不下就裁掉，不加省略号，同样宽度能多看到一两个字
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 17, maxHeight: 17)
                        .overlay(alignment: .leading) {
                            Text(item.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .fixedSize()
                                .foregroundStyle(item.eventText(scheme))
                                .padding(.leading, 3)
                        }
                        .clipped()
                        .background(RoundedRectangle(cornerRadius: 3).fill(item.eventFill(scheme)))
                }
                if items.count > 3 {
                    Text("+\(items.count - 3)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 1)
        }
    }
}

// MARK: - 日视图

/// 顶部周条可左右滑动换周，下面的时间轴左右滑动换天，和系统日历一样。
private struct DayScreen: View {
    let services: PhoneServices
    @Binding var selectedDay: Date
    let onOpen: (CalendarItem) -> Void

    private var cal: Calendar { services.calendar }

    private func offset(from start: Date) -> Int {
        cal.dateComponents([.day], from: start, to: selectedDay).day ?? 0
    }

    private var dayIndex: Binding<Int?> {
        Binding(
            get: { offset(from: CalendarRange.firstDay) },
            set: { index in
                if let index { selectedDay = cal.date(byAdding: .day, value: index, to: CalendarRange.firstDay) ?? selectedDay }
            }
        )
    }

    private var weekIndex: Binding<Int?> {
        Binding(
            get: { offset(from: CalendarRange.firstWeek) / 7 },
            set: { week in
                // 换周时保持星期几不变
                guard let week, week != offset(from: CalendarRange.firstWeek) / 7 else { return }
                let weekday = offset(from: CalendarRange.firstWeek) % 7
                selectedDay = cal.date(byAdding: .day, value: week * 7 + weekday, to: CalendarRange.firstWeek) ?? selectedDay
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<CalendarRange.weekCount, id: \.self) { week in
                        WeekStrip(week: cal.date(byAdding: .day, value: week * 7, to: CalendarRange.firstWeek)!,
                                  selected: selectedDay, calendar: cal) { selectedDay = $0 }
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: weekIndex)
            .scrollIndicators(.hidden)
            .frame(height: 58)

            Text("\(selectedDay.formatted("yyyy年M月d日 EEEE", calendar: cal))  \(Lunar.dayText(selectedDay))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            Divider()

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<CalendarRange.dayCount, id: \.self) { index in
                        let day = cal.date(byAdding: .day, value: index, to: CalendarRange.firstDay)!
                        DayTimeline(day: day, items: services.items(on: day), calendar: cal, onOpen: onOpen)
                            .containerRelativeFrame([.horizontal, .vertical])
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: dayIndex)
            .scrollIndicators(.hidden)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WeekStrip: View {
    let week: Date
    let selected: Date
    let calendar: Calendar
    let onSelect: (Date) -> Void

    private let names = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: week)!
                let isToday = calendar.isDateInToday(day)
                let isSelected = calendar.isDate(day, inSameDayAs: selected)
                VStack(spacing: 3) {
                    Text(names[offset])
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.background) : (isToday ? AnyShapeStyle(.red) : AnyShapeStyle(.primary)))
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
    @Environment(\.colorScheme) private var scheme

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
                            .foregroundStyle(item.eventText(scheme))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 4).fill(item.eventFill(scheme)))
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
    @Environment(\.colorScheme) private var scheme

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
        .foregroundStyle(item.eventText(scheme))
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(item.eventFill(scheme))
                RoundedRectangle(cornerRadius: 1.5).fill(item.eventBar(scheme)).frame(width: 3).padding(.vertical, 3).padding(.leading, 2)
            }
        }
        .contentShape(Rectangle())
    }
}
