import Foundation

public enum BillingCycle: Codable, Hashable, Sendable {
    case weekly
    case monthly
    case quarterly
    case yearly
    case everyDays(Int)

    var step: (Calendar.Component, Int) {
        switch self {
        case .weekly: (.day, 7)
        case .monthly: (.month, 1)
        case .quarterly: (.month, 3)
        case .yearly: (.year, 1)
        case .everyDays(let n): (.day, max(1, n))
        }
    }

    /// 折算成每月费用的分数（分子, 分母）；先乘后除，避免 1/12 这类循环小数的误差。
    var monthlyFraction: (numerator: Decimal, denominator: Decimal) {
        switch self {
        case .weekly: (52, 12)
        case .monthly: (1, 1)
        case .quarterly: (1, 3)
        case .yearly: (1, 12)
        case .everyDays(let n): (365, Decimal(12 * max(1, n)))
        }
    }
}

/// 一项付费订阅（会员、云服务、软件等），按周期自动生成续费提醒。
public struct Subscription: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var price: Decimal
    public var currency: String
    public var cycle: BillingCycle
    /// 第一次扣费日期，之后的续费日都从它按周期推算（避免月底日期漂移）。
    public var firstBillingDate: Date
    public var isActive: Bool
    public var notes: String?

    public init(id: UUID = UUID(), name: String, price: Decimal, currency: String = "CNY",
                cycle: BillingCycle, firstBillingDate: Date, isActive: Bool = true, notes: String? = nil) {
        self.id = id
        self.name = name
        self.price = price
        self.currency = currency
        self.cycle = cycle
        self.firstBillingDate = firstBillingDate
        self.isActive = isActive
        self.notes = notes
    }

    public var monthlyCost: Decimal {
        let (num, den) = cycle.monthlyFraction
        return price * num / den
    }

    /// `range` 内的所有续费日（取当天零点）。
    public func renewals(in range: DateInterval, calendar: Calendar = .current) -> [Date] {
        guard isActive else { return [] }
        let (component, amount) = cycle.step
        let anchor = calendar.startOfDay(for: firstBillingDate)
        var result: [Date] = []
        for n in 0..<5000 {
            guard let date = calendar.date(byAdding: component, value: n * amount, to: anchor) else { break }
            if date >= range.end { break }
            if date >= range.start { result.append(date) }
        }
        return result
    }

    public func nextRenewal(after date: Date = .now, calendar: Calendar = .current) -> Date? {
        let start = calendar.startOfDay(for: date)
        let horizon = calendar.date(byAdding: .year, value: 2, to: start) ?? start
        return renewals(in: DateInterval(start: start, end: horizon), calendar: calendar).first
    }
}
