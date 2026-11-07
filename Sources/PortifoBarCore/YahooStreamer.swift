import Foundation

// Yahoo's live price feed: the WebSocket finance.yahoo.com itself listens
// on. Subscribe to symbols and it pushes each trade as it prints, several
// times a second for a busy listing. Listings that aren't trading send
// nothing, and some never stream at all (^GSPC), so the feed is half the
// story: QuoteStore polls whatever it leaves quiet.
@MainActor
public final class YahooStreamer {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case live
        case retrying(at: Date)
    }

    public static let url = URL(string: "wss://streamer.finance.yahoo.com/?version=2")!

    // How often to ping, and how long the line may stay silent (no pong, no
    // frame) before it counts as dead. A quiet market sends no frames for
    // hours, so pings are what tell a dead line from a quiet one.
    static let pingEvery: Duration = .seconds(15)
    static let deadAfter: TimeInterval = 40
    static let maxBackoff: TimeInterval = 30

    public var onTick: (Tick) -> Void = { _ in }
    public var onStateChange: (State) -> Void = { _ in }

    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange(state) } }
    }

    private let session: URLSession
    private var symbols: Set<String> = []
    // What the open connection has been told to send.
    private var subscribed: Set<String> = []
    private var socket: URLSessionWebSocketTask?
    // Bumped whenever a connection is dropped, so its loops can tell they're
    // stale and stop.
    private var generation = 0
    private var failures = 0
    private var lastHeard = Date.distantPast
    private var suspended = false
    private var retry: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?

    public init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    // Streams exactly `wanted`, connecting if need be.
    public func track(_ wanted: Set<String>) {
        symbols = wanted
        if wanted.isEmpty {
            teardown()
            state = .idle
        } else if state == .idle, !suspended {
            connect()
        } else {
            sync()
        }
    }

    // A fresh connection now, with no backoff: after a wake, or when the
    // network comes back.
    public func reconnect() {
        suspended = false
        failures = 0
        connect()
    }

    // Hangs up until `reconnect()`, keeping the symbols.
    public func suspend() {
        suspended = true
        teardown()
        state = .idle
    }

    private func connect() {
        teardown()
        guard !symbols.isEmpty else {
            state = .idle
            return
        }
        var request = URLRequest(url: Self.url)
        request.setValue(YahooClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://finance.yahoo.com", forHTTPHeaderField: "Origin")
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        state = .connecting
        socket.resume()
        let generation = self.generation
        Task { await run(socket, generation: generation) }
    }

    private func run(_ socket: URLSessionWebSocketTask, generation: Int) async {
        do {
            // Without a delegate there's no open event: the first send
            // completes once the handshake has.
            let initial = symbols
            try await socket.send(.string(Self.command("subscribe", initial)))
            guard generation == self.generation else { return }
            subscribed = initial
            lastHeard = .now
            state = .live
            sync()
            startHeartbeat(socket, generation: generation)
            while true {
                let message = try await socket.receive()
                guard generation == self.generation else { return }
                lastHeard = .now
                failures = 0
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                if let tick = Tick(frame: text) { onTick(tick) }
            }
        } catch {
            guard generation == self.generation else { return }
            scheduleRetry()
        }
    }

    // Brings the open connection's subscriptions in line with `symbols`.
    private func sync() {
        guard state == .live, let socket else { return }
        let added = symbols.subtracting(subscribed)
        let removed = subscribed.subtracting(symbols)
        subscribed = symbols
        // A failed send fails the receive loop too, which reconnects.
        if !added.isEmpty {
            let command = Self.command("subscribe", added)
            Task { try? await socket.send(.string(command)) }
        }
        if !removed.isEmpty {
            let command = Self.command("unsubscribe", removed)
            Task { try? await socket.send(.string(command)) }
        }
    }

    private func startHeartbeat(_ socket: URLSessionWebSocketTask, generation: Int) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.pingEvery)
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                if Date.now.timeIntervalSince(self.lastHeard) > Self.deadAfter {
                    self.scheduleRetry()
                    return
                }
                socket.sendPing { [weak self] error in
                    guard error == nil else { return }
                    Task { @MainActor in
                        guard let self, generation == self.generation else { return }
                        self.lastHeard = .now
                    }
                }
            }
        }
    }

    // 1s, 2s, 4s… up to 30s, jittered so a fleet of clients doesn't return
    // in lockstep. Any frame resets it.
    private func scheduleRetry() {
        teardown()
        failures += 1
        let delay = min(Self.maxBackoff, pow(2, Double(failures - 1))) * Double.random(in: 0.8...1.2)
        state = .retrying(at: Date.now.addingTimeInterval(delay))
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.connect()
        }
    }

    private func teardown() {
        generation += 1
        retry?.cancel()
        retry = nil
        heartbeat?.cancel()
        heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        subscribed = []
    }

    private static func command(_ verb: String, _ symbols: Set<String>) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [verb: symbols.sorted()])
        return String(decoding: data, as: UTF8.self)
    }
}
