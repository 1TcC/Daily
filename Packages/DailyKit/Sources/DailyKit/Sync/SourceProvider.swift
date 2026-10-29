import Foundation

/// 一个可同步的数据来源。每次 `fetch` 返回该来源在 `range` 内的完整快照，
/// 每个条目都必须带 `externalID`，SyncEngine 据此去重和清理。
public protocol SourceProvider: Sendable {
    var sourceID: String { get }
    var kind: SourceKind { get }
    var displayName: String { get }
    func fetch(in range: DateInterval) async throws -> [CalendarItem]
}

/// 同步引擎：逐个拉取来源并写入存储；单个来源失败不影响其他来源。
public actor SyncEngine {
    private let store: ItemStore
    private var providers: [String: any SourceProvider] = [:]
    public private(set) var lastSynced: [String: Date] = [:]

    public init(store: ItemStore) {
        self.store = store
    }

    public func register(_ provider: any SourceProvider) {
        providers[provider.sourceID] = provider
    }

    public func unregister(sourceID: String) {
        providers[sourceID] = nil
    }

    /// 同步所有来源，返回失败来源的错误。
    @discardableResult
    public func syncAll(in range: DateInterval) async -> [String: any Error] {
        var failures: [String: any Error] = [:]
        for (id, provider) in providers {
            do {
                try await sync(provider, in: range)
            } catch {
                failures[id] = error
            }
        }
        return failures
    }

    public func sync(sourceID: String, in range: DateInterval) async throws {
        guard let provider = providers[sourceID] else { return }
        try await sync(provider, in: range)
    }

    private func sync(_ provider: any SourceProvider, in range: DateInterval) async throws {
        let items = try await provider.fetch(in: range)
        try store.replaceSnapshot(sourceID: provider.sourceID, in: range, with: items)
        lastSynced[provider.sourceID] = .now
    }
}
