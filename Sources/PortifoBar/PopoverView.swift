import PortifoBarCore
import SwiftUI

// What a click on the menu bar opens, and everything the app does: one
// symbol's chart under its price, the watchlist live beneath it
// (click a row to chart it, its pin to show it in the menu bar, a bar to
// compare the day's moves), a row to add a symbol, and the way to Settings
// and out.
struct PopoverView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.settings.symbols.isEmpty {
                Text("Add a symbol to follow its price in the menu bar.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ChartSection(model: model, chart: model.chart)
                    .padding(.horizontal, Metrics.inset)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
            }
            Divider()
            WatchlistSection(model: model)
                .padding(.vertical, 6)
            Divider()
            footer
        }
        .frame(width: Metrics.width)
        .background(MenuBackground())
        .modifier(FirstClickActs())
    }

    private var footer: some View {
        HStack(spacing: 2) {
            StatusLabel(status: model.status)
            Spacer()
            IconButton(systemImage: "gearshape", label: "Settings") { model.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            IconButton(systemImage: "power", label: "Quit Portifo Bar") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.leading, Metrics.inset)
        .padding(.trailing, Metrics.inset - 6)
        .padding(.vertical, 6)
    }
}

// The surface the menu bar's own menus are drawn on, Wi-Fi's and Control
// Center's: Liquid Glass on macOS 26, the menu material before it. Not the
// popover's own glass, which is far clearer: over a dark window it turns
// grey and the gains' green sinks into it. Frosted whether or not the app is
// active, as it often isn't while the popover is open.
private struct MenuBackground: View {
    var body: some View {
        if #available(macOS 26, *) {
            Glass()
        } else {
            MenuMaterial()
        }
    }

    @available(macOS 26, *)
    private struct Glass: NSViewRepresentable {
        func makeNSView(context: Context) -> NSGlassEffectView {
            let view = NSGlassEffectView()
            view.style = .regular
            return view
        }

        func updateNSView(_ view: NSGlassEffectView, context: Context) {}
    }

    private struct MenuMaterial: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .menu
            view.blendingMode = .behindWindow
            view.state = .active
            return view
        }

        func updateNSView(_ view: NSVisualEffectView, context: Context) {}
    }
}

// Every click in the popover acts, the first included. The popover can be
// open without its window being key: macOS doesn't always let the app come
// forward when the menu bar item is clicked, and another app can take the
// keyboard while it stays open. SwiftUI otherwise spends that first click
// on bringing the window forward, so a click on a watchlist row did nothing
// until it was clicked again.
private struct FirstClickActs: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.allowsWindowActivationEvents(true)
        } else {
            content
        }
    }
}

private enum Metrics {
    static let width: CGFloat = 460
    // Every section's text starts this far in, rows' included.
    static let inset: CGFloat = 16
    // Rows are inset by this, and their contents by the rest of `inset`,
    // so a row's highlight reaches nearer the edge than its text.
    static let rowOutset: CGFloat = 6
}

private enum Typography {
    // Tickers in plain SF Pro, a step bolder than the text around them.
    static func ticker(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold)
    }

    static let price = Font.system(size: 30, weight: .medium).monospacedDigit()
}

// MARK: The chart

private struct ChartSection: View {
    let model: AppModel
    @Bindable var chart: ChartModel

    // The points the line runs through: the bars, and overnight, the day's
    // latest trade past them.
    private func points(_ series: CandleSeries) -> [Candle] {
        series.line(through: chart.quote)
    }

    // With the SMA bands on, the 200-day average at each point and the lines
    // drawn about it, once the daily closes have come.
    private func bands(_ series: CandleSeries, _ points: [Candle]) -> SMABands? {
        guard let closes = chart.closes(covering: series) else { return nil }
        let average = MovingAverage.values(at: points.map(\.time), closes: closes)
        return SMABands(prices: points.map(\.close), average: average)
    }

    // What the line runs through: "Daily closes", "5-minute closes,
    // pre-market to after hours", "5-minute closes, last 24 hours".
    private func caption(_ series: CandleSeries) -> String {
        let span = series.lineSpan
        let each = span == .minutes(60) ? "Hourly" : span.name
        if series.isLast24Hours { return "\(each) closes, last 24 hours" }
        if series.extendedHours { return "\(each) closes, pre-market to after hours" }
        // Said where the listing trades outside the session but the line doesn't.
        if span.isIntraday, chart.quote?.hasExtendedHours == true { return "\(each) closes, regular hours" }
        return "\(each) closes"
    }

    var body: some View {
        @Bindable var settings = model.settings
        let line = chart.series.map { series in
            let points = points(series)
            return (series: series, points: points, bands: bands(series, points))
        }
        VStack(alignment: .leading, spacing: 0) {
            Hero(symbol: chart.symbol, quote: chart.quote) { model.openOnYahoo(chart.symbol) }
                .padding(.bottom, 16)
            readout
                .padding(.bottom, 4)
            plot(bands: line?.bands)
                .frame(height: 190)
                .padding(.bottom, 10)
            ChoiceRow(
                choices: ChartRange.allCases, selection: $settings.chartRange,
                label: \.label, spoken: \.spoken, help: "How far back the chart reaches"
            )
            .padding(.bottom, 6)
            indicators(line)
        }
    }

    // Under the range: the SMA bands' chip, which doubles as their legend,
    // reading how far the price sits from the average at the picked or
    // latest point; when the price crosses no line, not even the average,
    // which lines it stayed between; and what the line runs through, which
    // gives way first.
    private func indicators(_ line: (series: CandleSeries, points: [Candle], bands: SMABands?)?) -> some View {
        @Bindable var settings = model.settings
        let bands = line?.bands
        let at = line.flatMap { line in
            chart.selection.flatMap { line.points.indices.contains($0) ? $0 : nil }
                ?? bands?.average.lastIndex { $0 != nil }
        }
        let gap = line.flatMap { line in at.flatMap { bands?.gap(at: $0, price: line.points[$0].close) } }
        let chip = BandsChip(on: $settings.smaBands, gap: gap)
        let stayed = bands?.stayed.map { Text($0).foregroundStyle(.tertiary) }
        let closes = Text(line.map { caption($0.series) } ?? " ").foregroundStyle(.tertiary)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                chip
                stayed
                Spacer(minLength: 8)
                closes
            }
            HStack(spacing: 8) {
                chip
                stayed
                Spacer(minLength: 0)
            }
            HStack {
                chip
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 24)
    }

    // The point under the pointer, or the latest: what it spans (a sunrise
    // or a moon outside the regular session), its price and volume, and where
    // it stands against the previous close (or, over a longer range, the
    // close before it began), which gives way first when they don't all fit.
    // Brighter while one is picked.
    private var readout: some View {
        Group {
            if let series = chart.series, case let points = points(series), !points.isEmpty {
                let picked = chart.selection.flatMap { points.indices.contains($0) ? $0 : nil }
                let point = points[picked ?? points.count - 1]
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        if let icon = Style.symbolName(for: point.session) {
                            Image(systemName: icon)
                                .imageScale(.small)
                                .help(point.session.label ?? "")
                        }
                        Text(CandleText.span(point, span: series.lineSpan, in: series))
                    }
                    .foregroundStyle(picked == nil ? .secondary : .primary)
                    Spacer(minLength: 8)
                    ViewThatFits(in: .horizontal) {
                        figures(point, series, againstClose: true)
                        figures(point, series, againstClose: false)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(CandleText.when(point, span: series.lineSpan, in: series)): \(PriceFormat.price(point.close, decimals: series.decimals))"
                        + (point.volume.map { ", volume \(CandleText.volume($0))" } ?? "")
                )
            } else {
                Text(" ")
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
    }

    private func figures(_ point: Candle, _ series: CandleSeries, againstClose: Bool) -> some View {
        HStack(spacing: 8) {
            Text(PriceFormat.price(point.close, decimals: series.decimals))
            if let volume = point.volume, volume > 0 {
                HStack(spacing: 3) {
                    Text("V").foregroundStyle(.tertiary)
                    Text(CandleText.volume(volume))
                }
            }
            if againstClose, let close = series.reference(at: point.time), close != 0 {
                let percent = (point.close - close) / close * 100
                Text(PriceFormat.percent(percent)).foregroundStyle(moveColor(percent))
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func plot(bands: SMABands?) -> some View {
        if let series = chart.series, case let points = points(series), points.count > 1 {
            LineChart(series: series, points: points, bands: bands, selection: $chart.selection, shown: chart.visible)
        } else if let series = chart.series {
            centred(Text(series.range == .day ? "No trades yet today" : "No prices for this range").foregroundStyle(.secondary))
        } else if chart.failed {
            centred(VStack(spacing: 8) {
                Text("Couldn't load the chart from Yahoo Finance.").foregroundStyle(.secondary)
                Button("Try Again") { chart.load() }
            })
        } else {
            centred(ProgressView().controlSize(.small))
        }
    }

    private func centred(_ content: some View) -> some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// The charted symbol: its ticker and name, then its price large, with the
// day's move beside it and any pre-market or after-hours trade beneath.
private struct Hero: View {
    let symbol: String
    let quote: Quote?
    let openOnYahoo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                Text(symbol)
                    .font(Typography.ticker(13))
                    .layoutPriority(1)
                Text(quote?.name ?? "")
                    .foregroundStyle(.secondary)
                    .help(quote?.exchange ?? "")
                Spacer(minLength: 8)
                IconButton(systemImage: "arrow.up.forward.square", label: "Open \(symbol) on Yahoo Finance", action: openOnYahoo)
                    .padding(.trailing, -6)
            }
            .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(quote.map { PriceFormat.price($0.price, decimals: $0.decimals) } ?? " ")
                        .font(Typography.price)
                    if let currency = quote?.currency {
                        Text(currency)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let quote {
                    MoveText(
                        change: quote.previousClose.map { quote.price - $0 },
                        percent: quote.previousClose.flatMap { $0 != 0 ? (quote.price - $0) / $0 * 100 : nil },
                        decimals: quote.decimals
                    )
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                }
            }

            if let quote, let extended = quote.extended {
                let latest = quote.latest
                HStack(spacing: 5) {
                    if let icon = Style.symbolName(for: extended.session) {
                        Image(systemName: icon)
                    }
                    Text(extended.session.label ?? "")
                    Text(PriceFormat.price(extended.price, decimals: quote.decimals))
                        .foregroundStyle(.primary)
                        .padding(.leading, 2)
                    MoveText(change: latest.change, percent: latest.changePercent, decimals: quote.decimals)
                }
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }
}

// A move with its direction drawn as well as signed and coloured: up and
// down don't rest on red and green alone.
private struct MoveText: View {
    let change: Double?
    let percent: Double?
    let decimals: Int

    var body: some View {
        if let percent {
            let up = percent > 0
            let flat = Style.color(for: percent) == nil
            HStack(spacing: 4) {
                if !flat {
                    Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                Text(change.map { "\(PriceFormat.change($0, decimals: decimals)) (\(PriceFormat.percent(percent)))" }
                    ?? PriceFormat.percent(percent))
            }
            .foregroundStyle(flat ? Color.secondary : moveColor(percent))
        }
    }
}

// Portifo's indicator toggle: a swatch of the lines it draws (a band above
// the average, the dashed average, a band below, as the chart stacks them),
// its name and, when on, how far the price sits from the average. Off, it
// reads in the secondary ink with a muted swatch.
private struct BandsChip: View {
    @Binding var on: Bool
    let gap: Double?
    @State private var hovering = false

    var body: some View {
        Button {
            on.toggle()
        } label: {
            HStack(spacing: 6) {
                VStack(spacing: 2) {
                    Swatch(color: on ? Color(nsColor: Style.bandAbove) : muted)
                    Swatch(color: on ? Color(nsColor: Style.ink) : muted, dashed: true)
                    Swatch(color: on ? Color(nsColor: Style.bandBelow) : muted)
                }
                .frame(width: 12, height: 10)
                Text("SMA bands")
                if on, let gap {
                    Text(PriceFormat.percent(gap, decimals: 1))
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(on ? .primary : .secondary)
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.04 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: Style.line)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("The 200-day moving average, with bands 5, 10 and 15% either side of it")
        .accessibilityLabel("SMA bands")
        .accessibilityValue(on ? gap.map { "On, price \(PriceFormat.percent($0, decimals: 1)) from the 200-day average" } ?? "On" : "Off")
    }

    private var muted: Color { Color(nsColor: Style.muted) }
}

// One quiet button a choice, spread under the chart: how far back it reaches.
private struct ChoiceRow<Choice: Hashable & Identifiable>: View {
    let choices: [Choice]
    @Binding var selection: Choice
    let label: (Choice) -> String
    // For VoiceOver: "1 year".
    let spoken: (Choice) -> String
    let help: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices) { choice in
                let selected = choice == selection
                Button {
                    selection = choice
                } label: {
                    Text(label(choice))
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.primary.opacity(0.09) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(spoken(choice))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .help(help)
    }
}

// MARK: The watchlist

private struct WatchlistSection: View {
    let model: AppModel
    // Past this many rows the list scrolls rather than growing the popover.
    private static let visibleRows = 6
    private static let rowHeight: CGFloat = 38

    var body: some View {
        let symbols = model.settings.symbols
        VStack(spacing: 0) {
            if symbols.count > Self.visibleRows {
                ScrollView { rows(symbols) }
                    .frame(height: CGFloat(Self.visibleRows) * Self.rowHeight)
            } else {
                rows(symbols)
            }
            AddRow(model: model)
        }
        .padding(.horizontal, Metrics.rowOutset)
    }

    private func rows(_ symbols: [String]) -> some View {
        // The move bars share a scale, set by the biggest mover, but never
        // finer than 1%, so a quiet day's bars stay short.
        let scale = max(symbols.compactMap { model.quotes[$0]?.latest.changePercent.map(abs) }.max() ?? 0, 1)
        return VStack(spacing: 0) {
            ForEach(symbols, id: \.self) { symbol in
                WatchRow(
                    symbol: symbol,
                    quote: model.quotes[symbol],
                    selected: symbol == model.chart.symbol,
                    pinned: model.isPinned(symbol),
                    scale: scale,
                    model: model
                )
                .frame(height: Self.rowHeight)
            }
        }
    }
}

private struct WatchRow: View {
    let symbol: String
    let quote: Quote?
    let selected: Bool
    let pinned: Bool
    let scale: Double
    let model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(symbol).font(Typography.ticker(12))
                Text(quote?.name ?? " ")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if let quote {
                let latest = quote.latest
                HStack(spacing: 4) {
                    if let icon = Style.symbolName(for: latest.session) {
                        Image(systemName: icon)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help(latest.session.label ?? "")
                    }
                    Text(PriceFormat.price(latest.price, decimals: quote.decimals))
                        .font(.system(size: 13).monospacedDigit())
                }
                MoveBar(percent: latest.changePercent, scale: scale)
                Text(latest.changePercent.map { PriceFormat.percent($0) } ?? "—")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(latest.changePercent.map(moveColor) ?? .secondary)
                    .frame(width: 58, alignment: .trailing)
            } else {
                ProgressView().controlSize(.mini)
            }
            pin
        }
        .padding(.leading, Metrics.inset - Metrics.rowOutset)
        .padding(.trailing, 4)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(selected ? 0.08 : hovering ? 0.04 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.select(symbol) }
        .onHover { hovering = $0 }
        .help("Chart \(symbol)")
        .contextMenu {
            Button("Chart \(symbol)") { model.select(symbol) }
            Button(pinned ? "Take Off the Menu Bar" : "Show in the Menu Bar") { model.togglePinned(symbol) }
            Button("Open on Yahoo Finance") { model.openOnYahoo(symbol) }
            Divider()
            Button("Remove from Watchlist") { model.remove(symbol) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: pinned ? "Take off the menu bar" : "Show in the menu bar") { model.togglePinned(symbol) }
    }

    // Always there for a symbol in the menu bar; for the rest, only under
    // the pointer.
    private var pin: some View {
        Button {
            model.togglePinned(symbol)
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 11))
                .foregroundStyle(pinned ? Color.accentColor : .secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(pinned || hovering ? 1 : 0)
        .allowsHitTesting(pinned || hovering)
        .help(pinned ? "In the menu bar: click to take it off" : "Show in the menu bar")
    }
}

// The day's move as a bar from a centre line, right for up and left for
// down, against the watchlist's shared scale: which symbols moved most,
// at a glance, without reading the figures.
private struct MoveBar: View {
    let percent: Double?
    let scale: Double

    var body: some View {
        let color = percent.flatMap { Style.color(for: $0) }.map { Color(nsColor: $0) }
        let fraction = percent.map { min(abs($0) / scale, 1) } ?? 0
        let up = (percent ?? 0) > 0
        Canvas { context, size in
            let mid = (size.width / 2).rounded()
            let thickness: CGFloat = 4
            let y = (size.height - thickness) / 2
            // The track, the scale's full reach either way, and the centre.
            let track = CGRect(x: 0, y: y, width: size.width, height: thickness)
            context.fill(Path(roundedRect: track, cornerRadius: thickness / 2), with: .color(.primary.opacity(0.06)))
            context.fill(Path(CGRect(x: mid - 0.5, y: 0, width: 1, height: size.height)), with: .color(.primary.opacity(0.22)))
            guard let color else { return }
            let length = max(CGFloat(fraction) * (mid - 1), 2)
            let rect = up
                ? CGRect(x: mid + 1, y: y, width: length, height: thickness)
                : CGRect(x: mid - 1 - length, y: y, width: length, height: thickness)
            context.fill(Path(roundedRect: rect, cornerRadius: thickness / 2), with: .color(color))
        }
        .frame(width: 44, height: 12)
        .accessibilityHidden(true)
    }
}

// The watchlist's last row: a quiet button that opens into the field, so the
// field doesn't take the keyboard every time the popover opens. With nothing
// to watch yet, the field is open and waiting.
private struct AddRow: View {
    let model: AppModel
    @State private var adding = false
    @State private var hovering = false

    var body: some View {
        if adding || model.settings.symbols.isEmpty {
            AddSymbolField(model: model, autofocus: true) { adding = false }
                .padding(.horizontal, Metrics.inset - Metrics.rowOutset)
                .padding(.vertical, 5)
                // The button's height, so the popover doesn't jump as it opens.
                .frame(minHeight: 30)
        } else {
            Button {
                adding = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                    Text("Add a symbol")
                }
                .font(.system(size: 12))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .padding(.horizontal, Metrics.inset - Metrics.rowOutset)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.04 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

// A symbol or a name, added on Return. Shared with Settings.
struct AddSymbolField: View {
    let model: AppModel
    // Take the keyboard on appearing: the popover's add row.
    var autofocus = false
    // Told after an add, or on Escape: the popover's add row folds away.
    var onDone: (() -> Void)?
    @State private var text = ""
    @State private var working = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                // Label hidden: a Form would otherwise set it beside the field.
                TextField("Add a symbol", text: $text, prompt: Text("Symbol or company: AAPL, SHOP.TO, Shopify"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand(perform: cancel)
                    .disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            guard autofocus else { return }
            // A beat later: the popover's window isn't key on the first pass.
            Task { focused = true }
        }
    }

    private func submit() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        working = true
        problem = nil
        Task {
            let result = await model.add(query)
            working = false
            switch result {
            case .added:
                text = ""
                onDone?()
            case .notFound: problem = "Yahoo Finance has no symbol matching “\(query)”."
            case .failed: problem = "Couldn't reach Yahoo Finance. Try again in a moment."
            }
        }
    }

    private func cancel() {
        text = ""
        problem = nil
        onDone?()
    }
}

// MARK: Controls

// A borderless symbol button that lights under the pointer, as a toolbar's do.
private struct IconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: Status

// The feed's state, a dot and its words.
struct StatusLabel: View {
    let status: AppModel.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
    }

    private var text: String {
        switch status {
        case .live: "Live from Yahoo Finance"
        case .connecting: "Connecting to Yahoo Finance…"
        case .reconnecting: "Reconnecting…"
        case .paused: "Paused"
        case .rateLimited: "Yahoo is rate-limiting; backing off"
        case .unreachable: "Can't reach Yahoo Finance"
        }
    }

    private var color: Color {
        switch status {
        case .live: .green
        case .connecting, .reconnecting: .yellow
        case .paused: .gray
        case .rateLimited: .orange
        case .unreachable: .red
        }
    }
}

@MainActor
private func moveColor(_ percent: Double) -> Color {
    Style.color(for: percent).map { Color(nsColor: $0) } ?? .primary
}
