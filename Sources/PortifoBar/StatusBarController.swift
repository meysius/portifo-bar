import AppKit
import PortifoBarCore
import SwiftUI

// The menu bar item: each pinned symbol's latest price (pre-market and after
// hours included, marked by a sunrise or a moon) and its move. A click, left
// or right, opens the popover, where everything else lives; Settings opens
// its own window.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    // How long a price stays tinted after it moves.
    private static let flashFor: TimeInterval = 0.6
    // How long a trading symbol may go with nothing new from either feed
    // before its price is greyed as stale: two refreshes missed.
    private static let staleAfter: TimeInterval = QuoteStore.tradingRefresh * 2 + 15

    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    // A click on the bar while the popover is open closes it on mouse-down,
    // before the click's own action runs; this stops that action reopening it.
    private var popoverClosedAt = Date.distantPast
    // While the popover is open, a click anywhere outside the app closes it.
    // `.transient` alone closes it only when the app stops being active, and
    // macOS doesn't always make the app active when the menu bar item is
    // clicked, so clicks in other apps, on the desktop or in the menu bar
    // went by and left it open.
    private var outsideClicks: Any?
    // Each pinned symbol's price as last drawn, to tell which way it moved.
    private var drawn: [String: Double] = [:]
    private var flashes: [String: (up: Bool, until: Date)] = [:]
    private var clock: Timer?

    init(model: AppModel) {
        self.model = model
        super.init()
        item.autosaveName = "PortifoBar"
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        model.onQuote = { [weak self] symbol in self?.quoteChanged(symbol) }
        model.onSettingsChange = { [weak self] in self?.renderBar() }
        model.onOpenSettings = { [weak self] in self?.openSettings() }

        // Staleness comes with time passing, not with updates.
        let clock = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderBar() }
        }
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
        renderBar()
    }

    // MARK: Clicks

    @objc private func clicked() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard Date.now.timeIntervalSince(popoverClosedAt) > 0.3, let button = item.button else { return }
        model.prepareChart()
        model.chart.start()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidShow(_ notification: Notification) {
        guard outsideClicks == nil else { return }
        // Clicks in this app, the menu bar item's included, aren't seen here:
        // the popover handles those itself.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        popoverClosedAt = .now
        model.chart.stop()
    }

    private func openSettings() {
        popover.performClose(nil)
        let window = settingsWindow ?? {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "Portifo Bar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
            return window
        }()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: The bar

    private func quoteChanged(_ symbol: String) {
        guard model.settings.pinned.contains(symbol) else { return }
        noteMove(symbol)
        renderBar()
    }

    private func noteMove(_ symbol: String) {
        guard let price = model.store.quotes[symbol]?.latest.price else { return }
        defer { drawn[symbol] = price }
        guard model.settings.flash, let old = drawn[symbol], old != price else { return }
        flashes[symbol] = (price > old, Date.now.addingTimeInterval(Self.flashFor))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.flashFor + 0.02))
            self?.renderBar()
        }
    }

    private func renderBar() {
        guard let button = item.button else { return }
        let symbols = model.settings.menuBar
        if symbols.isEmpty {
            button.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "Portifo Bar")
            button.attributedTitle = NSAttributedString()
            return
        }
        button.image = nil
        let font = Style.barFont
        let title = NSMutableAttributedString()
        for (i, symbol) in symbols.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
            title.append(segment(symbol, font: font))
        }
        button.attributedTitle = title
    }

    private func segment(_ symbol: String, font: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "\(symbol) ", attributes: [.font: font])
        guard let quote = model.store.quotes[symbol] else {
            out.append(NSAttributedString(string: "—", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            return out
        }
        let latest = quote.latest
        let now = Date.now
        if let icon = Style.icon(for: latest.session, font: font) { out.append(icon) }

        var priceAttributes: [NSAttributedString.Key: Any] = [.font: font]
        if isStale(symbol, quote, at: now) {
            priceAttributes[.foregroundColor] = NSColor.secondaryLabelColor
        } else if let flash = flashes[symbol], flash.until > now {
            priceAttributes[.foregroundColor] = flash.up ? Style.positive : Style.negative
        }
        out.append(NSAttributedString(string: PriceFormat.price(latest.price, decimals: quote.decimals), attributes: priceAttributes))

        let move: String?
        let color: NSColor?
        switch model.settings.changeStyle {
        case .percent:
            move = latest.changePercent.map { PriceFormat.percent($0) }
            color = Style.color(for: latest.changePercent)
        case .amount:
            move = latest.change.map { PriceFormat.change($0, decimals: quote.decimals) }
            color = Style.color(for: latest.change, decimals: quote.decimals)
        case .none:
            move = nil
            color = nil
        }
        if let move {
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if let color { attributes[.foregroundColor] = color }
            out.append(NSAttributedString(string: " " + move, attributes: attributes))
        }
        return out
    }

    private func isStale(_ symbol: String, _ quote: Quote, at now: Date) -> Bool {
        quote.isTrading(at: now) && now.timeIntervalSince(model.store.lastReceived[symbol] ?? .distantPast) > Self.staleAfter
    }
}
