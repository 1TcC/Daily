import Foundation

/// 和中转服务保持的 WebSocket 长连接：Grok 改了日程，中转服务立即推一条通知，收到后由 App 拉取。
/// 断线自动重连（间隔从 2 秒逐步拉长到 60 秒）；每 30 秒发一次心跳，中转服务直接回 "pong"。
@MainActor
public final class RelayLiveChannel {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private let onStateChange: @MainActor (Bool) -> Void
    private var task: URLSessionWebSocketTask?
    private var heartbeat: Timer?
    private var reconnect: Task<Void, Never>?
    private var retryDelay: TimeInterval = 2
    private var stopped = true
    public private(set) var isConnected = false {
        didSet { if oldValue != isConnected { onStateChange(isConnected) } }
    }

    public init(connection: RelayConnection,
                onChange: @escaping @MainActor () -> Void,
                onStateChange: @escaping @MainActor (Bool) -> Void = { _ in }) {
        var components = URLComponents(url: connection.baseURL.appendingPathComponent("sync/live"),
                                       resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        url = components.url!
        self.onChange = onChange
        self.onStateChange = onStateChange
    }

    public func start() {
        stopped = false
        retryDelay = 2
        connect()
    }

    public func stop() {
        stopped = true
        reconnect?.cancel()
        heartbeat?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    /// 例如 Mac 从睡眠唤醒后，旧连接多半已失效，直接重建。
    public func restart() {
        guard !stopped else { return }
        task?.cancel(with: .goingAway, reason: nil)
        retryDelay = 2
        connect()
    }

    private func connect() {
        reconnect?.cancel()
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(on: task)
        send("ping", on: task)
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let task = self.task else { return }
                self.send("ping", on: task)
            }
        }
    }

    private func send(_ text: String, on task: URLSessionWebSocketTask) {
        task.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.disconnected(task) }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            let text: String? = switch result {
            case .success(.string(let s)): s
            case .success(.data(let d)): String(decoding: d, as: UTF8.self)
            default: nil
            }
            let failed = if case .failure = result { true } else { false }
            Task { @MainActor in
                guard let self, self.task === task else { return }
                if failed {
                    self.disconnected(task)
                    return
                }
                self.isConnected = true
                self.retryDelay = 2
                if let text, text.contains("agent-changed") { self.onChange() }
                self.receive(on: task)
            }
        }
    }

    private func disconnected(_ task: URLSessionWebSocketTask) {
        guard self.task === task else { return }
        isConnected = false
        heartbeat?.invalidate()
        self.task = nil
        guard !stopped else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
            // 重连后补拉一次，断线期间的变化不会漏掉
            self?.onChange()
        }
    }
}
