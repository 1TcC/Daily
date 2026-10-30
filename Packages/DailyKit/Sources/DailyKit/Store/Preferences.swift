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
}
