import Foundation

/// App 与 Widget 共享的存储位置。
public enum AppGroup {
    /// App Group 标识写在 Info.plist 的 `DailyAppGroup` 里（构建时由 Xcode 填入 TeamID 前缀）。
    public static var identifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "DailyAppGroup") as? String
    }

    /// 共享容器；拿不到时（例如命令行运行、签名未配置）退回到 Application Support/Daily。
    public static var containerURL: URL {
        if let id = identifier,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            return url
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Daily", isDirectory: true)
    }

    public static var databaseURL: URL { containerURL.appendingPathComponent("daily.sqlite") }
}
