import AppKit
import Network
import PortifoBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = QuoteStore()
    private var model: AppModel?
    private var controller: StatusBarController?
    private let network = NWPathMonitor()
    private var online = true
    // Asleep, or the screens off: nobody can see the menu bar, so the feeds
    // hang up until they're back.
    private var asleep = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel(store: store, settings: Settings())
        self.model = model
        controller = StatusBarController(model: model)
        // For working on the settings window: open it straight away.
        if CommandLine.arguments.contains("--open-settings") { model.openSettings() }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(true) }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(false) }
            }
        }

        network.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.setOnline(up) }
        }
        network.start(queue: DispatchQueue(label: "app.portifo.bar.network"))
    }

    private func setAsleep(_ value: Bool) {
        guard value != asleep else { return }
        asleep = value
        if value { store.pause() } else { store.resume() }
    }

    // Back online: reconnect now rather than at the end of a backoff.
    private func setOnline(_ value: Bool) {
        defer { online = value }
        if value, !online, !asleep { store.reconnect() }
    }
}
