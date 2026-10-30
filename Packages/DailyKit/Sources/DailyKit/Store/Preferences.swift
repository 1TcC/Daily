import Foundation

/// 存在 App Group 的 UserDefaults 里的用户设置，App 和 Widget 都能读到。
public struct Preferences: Sendable {
    public static let shared = Preferences(suiteName: AppGroup.identifier)

    private let suiteName: String?

    public init(suiteName: String?) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// 主窗口的字体缩放比例。
    public var textScale: Double {
        get { defaults.object(forKey: "textScale") as? Double ?? 1.15 }
        nonmutating set { defaults.set(newValue, forKey: "textScale") }
    }

    /// 侧边栏「系统日历」下的日历列表是否展开（默认收起）。
    public var systemCalendarsExpanded: Bool {
        get { defaults.bool(forKey: "systemCalendarsExpanded") }
        nonmutating set { defaults.set(newValue, forKey: "systemCalendarsExpanded") }
    }

    /// 中转服务的手机直连域名（Pages 网关），见 `RelayConnection.publicHost`。
    public var relayPublicHost: String? {
        get { defaults.string(forKey: "relayPublicHost") }
        nonmutating set { defaults.set(newValue, forKey: "relayPublicHost") }
    }

    /// 教务系统网址（导入课表时打开）。
    public var courseSiteURL: String {
        get { defaults.string(forKey: "courseSiteURL") ?? "https://classes.tju.edu.cn/eams/homeExt.action" }
        nonmutating set { defaults.set(newValue, forKey: "courseSiteURL") }
    }

    /// 不同步的系统日历（EKCalendar.calendarIdentifier）。
    public var excludedCalendarIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "excludedCalendarIDs") ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: "excludedCalendarIDs") }
    }

    /// 周 / 日视图的时间轴默认从几点开始（更早的日程会把它提前）。
    public var timelineStartHour: Int {
        get { defaults.object(forKey: "timelineStartHour") as? Int ?? 7 }
        nonmutating set { defaults.set(newValue, forKey: "timelineStartHour") }
    }

    /// 是否在菜单栏显示 Daily 图标（关闭主窗口后仍在后台同步）。
    public var showMenuBarIcon: Bool {
        get { defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "showMenuBarIcon") }
    }

    public var reminders: ReminderSettings {
        get {
            defaults.data(forKey: "reminders").flatMap { try? JSONDecoder().decode(ReminderSettings.self, from: $0) }
                ?? ReminderSettings()
        }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "reminders") }
    }

    /// 已经发过「收到取件码」通知的快递，避免重复通知。只保留最近 200 个。
    public var notifiedParcelIDs: [String] {
        get { defaults.stringArray(forKey: "notifiedParcelIDs") ?? [] }
        nonmutating set { defaults.set(Array(newValue.suffix(200)), forKey: "notifiedParcelIDs") }
    }
}
