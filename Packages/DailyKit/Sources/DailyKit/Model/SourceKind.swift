import Foundation

/// 日程条目的来源大类，决定颜色、图标和侧边栏分组。
public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case course
    case systemCalendar
    case message
    case travel
    case parcel
    case subscription
    case agent
    case manual

    public var displayName: String {
        switch self {
        case .course: "教务课程"
        case .systemCalendar: "系统日历"
        case .message: "邮件 / 微信识别"
        case .travel: "交通出行"
        case .parcel: "快递外卖"
        case .subscription: "订阅管理"
        case .agent: "Agent / Bot 写入"
        case .manual: "我的日程"
        }
    }
}
