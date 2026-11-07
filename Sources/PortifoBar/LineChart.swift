import Accessibility
import PortifoBarCore
import SwiftUI

// The chart, drawn as Portifo draws a holding's history (HoldingChart and
// lib/chartAxis in packages/portifo-web), itself modelled on Apple Stocks:
// one line through each bar's close, stretched from the range's low to its
// high over trading time only, a price scale at the right, a time scale
// beneath, the volume traded under that, and the latest price as a dot. The
// day runs from its pre-market to its after hours, as Portifo's does with
// Extended hours on: those stretches sit on a recessed ground with the line
// faded through them, so the regular session still reads as the day, and its
// latest price is tagged on the scale. Until the open it is the day before,
// with today's pre-market after its after hours, a guide naming the new day
// where it begins (see CandleSeries). The pointer or the arrow keys pick a
// point; the readout above the chart gives its figures.
//
// With the SMA bands on, the 200-day average is drawn inside bands 5, 10 and
// 15% either side of it, as Portifo draws them: of the bands, only those the
// price crosses, and only the lines the price crosses set the scale, so a
// price 18% above its average doesn't flatten the day's move into a line
// along the top. The average is always drawn, cut off at the plot's edge
// where it runs outside it; when it ends outside, its name points to it
// there ("SMA ↓"). The average is a dashed ink line, the bands above it teal
// and those below orange, their zones tinted deeper the farther out, and
// each line is named at its right end. A pick reads every drawn line beside
// the crosshair, top down as they cross it, the price slotted in where it
// sits. Portifo's earnings lines are left out.
struct LineChart: View {
    let series: CandleSeries
    // The points to draw: `series.line(through:)`.
    let points: [Candle]
    // The average at each point and the lines drawn about it, when on.
    var bands: SMABands?
    @Binding var selection: Int?
    // Whether the popover is open: the chart takes the keyboard when it opens.
    var shown = true

    var body: some View {
        let colors = LineLayout.Colors(
            accent: Color(nsColor: Style.accent),
            line: Color(nsColor: Style.line),
            muted: Color(nsColor: Style.muted),
            subtle: Color(nsColor: Style.subtle),
            background: Color(nsColor: .windowBackgroundColor),
            ink: Color(nsColor: Style.ink),
            bandAbove: Color(nsColor: Style.bandAbove),
            bandBelow: Color(nsColor: Style.bandBelow),
            secondary: Color(nsColor: Style.secondary)
        )
        let extended = points.contains { $0.session != .regular }
        GeometryReader { geometry in
            let layout = LineLayout(series: series, points: points, bands: bands, size: geometry.size)
            Canvas { context, _ in
                layout.draw(in: &context, selection: selection, colors: colors)
            }
            // Hangs beside the crosshair, on the side with more room, so the
            // crossings themselves stay in view.
            .overlay(alignment: .topLeading) {
                if let i = selection, let rungs = layout.rungs(at: i, colors: colors), let place = layout.ladderPlace(at: i) {
                    let ladder = Ladder(rungs: rungs, decimals: series.decimals, colors: colors)
                    Group {
                        switch place {
                        case .after(let x): ladder.padding(.leading, x)
                        case .before(let x): ladder.frame(width: x, alignment: .trailing)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): selection = layout.index(nearestX: point.x)
                case .ended: selection = nil
                }
            }
        }
        .modifier(ChartKeys(selection: $selection, count: points.count, shown: shown))
        .accessibilityElement()
        .accessibilityLabel(
            "\(series.symbol) \(series.isLast24Hours ? "over the last 24 hours" : series.spansDays ? "over its last trading day and today's pre-market" : series.range.phrase)"
                + (extended ? ", with pre-market and after-hours trading" : "")
                + (bands == nil ? "" : ", with its 200-day average and the bands about it that it crosses")
        )
        .accessibilityChartDescriptor(LineChartDescriptor(series: series, points: points, average: bands?.average))
    }
}

// One line's reading beside the crosshair.
struct Rung {
    enum Kind { case band, average, price }
    let label: String
    let value: Double
    let color: Color
    let kind: Kind
}

// The lines on the crosshair, top down, each with a swatch in its colour
// (dashed for the average, as it's drawn), its name and its value. The
// price's row is the bold one.
private struct Ladder: View {
    let rungs: [Rung]
    let decimals: Int
    let colors: LineLayout.Colors

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 1) {
            ForEach(rungs.indices, id: \.self) { i in
                let rung = rungs[i]
                GridRow {
                    Swatch(color: rung.color, dashed: rung.kind == .average)
                        .frame(width: 10, height: 2)
                    Text(rung.label)
                        .font(rung.kind == .band ? .system(size: 10, design: .monospaced) : .system(size: 10))
                    Text(PriceFormat.price(rung.value, decimals: decimals))
                        .gridColumnAlignment(.trailing)
                }
                .fontWeight(rung.kind == .price ? .semibold : .regular)
            }
        }
        .font(.system(size: 10).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.top, 4)
        .padding(.bottom, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(colors.background))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(colors.line))
        .fixedSize()
    }
}

// A short stroke in a line's colour, dashed like the average where it is one.
struct Swatch: View {
    let color: Color
    var dashed = false

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: size.height, dash: dashed ? [4, 2] : []))
        }
    }
}

// A chart's keyboard: it takes focus as the popover opens, so ← and → step
// through its points straight away, and Esc lets go of the one picked.
struct ChartKeys: ViewModifier {
    @Binding var selection: Int?
    let count: Int
    let shown: Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onChange(of: shown, initial: true) { _, shown in
                // A beat later: the popover's window isn't key on the first pass.
                if shown { Task { focused = true } }
            }
            .onKeyPress(.leftArrow) { step(-1) }
            .onKeyPress(.rightArrow) { step(1) }
            .onKeyPress(.escape) {
                selection = nil
                return .handled
            }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        selection = min(max((selection ?? count) + delta, 0), count - 1)
        return .handled
    }
}

// Where everything goes for one line at one size. Points sit at equal steps,
// not at their times, so the market's closed hours take no width: a week is
// five equal sessions, not five slivers joined by straight overnight lines,
// and on the day the regular session takes under half the width. The plot is
// fitted to the line's own low and high, so the low touches the baseline and
// the high reaches the top, and split into four equal bands whose top edges
// are labelled at the right. The labels keep the stretch honest: a 1% wobble
// fills the plot exactly as a 50% run does, and only the scale beside it
// tells them apart.
struct LineLayout {
    // Portifo's: the price line, guides, volume and baseline, the ground
    // under extended hours, and a solid surface, which backs the hover's
    // ladder and inks the price tag.
    struct Colors {
        let accent: Color
        let line: Color
        let muted: Color
        let subtle: Color
        let background: Color
        // The SMA bands': the average, the bands above and below it, and
        // the lines' names.
        let ink: Color
        let bandAbove: Color
        let bandBelow: Color
        let secondary: Color

        func color(for level: SMABands.Level) -> Color {
            level.offset > 0 ? bandAbove : level.offset < 0 ? bandBelow : ink
        }
    }

    // Portifo's measures, but for the plot's height, which takes what the
    // popover leaves it.
    private static let plotTop: CGFloat = 4 // room for the latest-price dot
    private static let axisHeight: CGFloat = 24 // the time labels' row
    private static let volumeGap: CGFloat = 8
    private static let volumeHeight: CGFloat = 18
    private static let bands = 4
    // Both scales' labels are mono, at a size whose digits advance 0.6em.
    private static let labelFont = Font.system(size: 10, design: .monospaced)
    private static let charWidth: CGFloat = 6
    private static let axisGap: CGFloat = 8
    private static let labelInset: CGFloat = 5 // a time label's gap from its guide
    // How strongly the line reads where it runs through extended hours.
    private static let extendedOpacity = 0.4
    // The day's latest price, tagged on the scale.
    private static let tagHeight: CGFloat = 18
    private static let tagPadding: CGFloat = 5
    private static let tagGap: CGFloat = 4 // from the plot's edge
    // A scale label's glyphs centre this far under its hairline.
    private static let labelMid: CGFloat = 8
    private static let labelHalf: CGFloat = 6
    // Each drawn line of the SMA bands is named just past its right end, in
    // a column of its own between the plot and the price scale, so no name
    // ever covers the price. Where lines run closer than a name is tall, the
    // names are spaced apart about their lines.
    private static let nameFont = Font.system(size: 9, design: .monospaced)
    private static let nameCharWidth: CGFloat = 5.4
    private static let nameInset: CGFloat = 6
    private static let nameGap: CGFloat = 11
    // The average's dashes, and how deep each band's zone is tinted.
    private static let averageDash: [CGFloat] = [4, 3]
    private static func tint(_ level: SMABands.Level) -> Double {
        switch abs(level.offset) {
        case 0.15: 0.13
        case 0.10: 0.09
        default: 0.05
        }
    }
    // The ladder's distance from the crosshair.
    private static let ladderGap: CGFloat = 10

    private let points: [Candle]
    private let plotWidth: CGFloat
    private let plotHeight: CGFloat
    private let width: CGFloat
    private let height: CGFloat
    private let xs: [CGFloat]
    private let ys: [CGFloat]
    private let valueTicks: [(y: CGFloat, label: String)]
    private let timeTicks: [(x: CGFloat, label: String)]
    // The regular session's first and last point (nil before the open), and
    // the stretches either side of it, when the line runs into extended hours.
    private let regular: ClosedRange<Int>?
    private let shade: [ClosedRange<CGFloat>]
    private let tag: String?
    // The scale's low and high.
    private let lo: Double
    private let hi: Double
    // The SMA bands, when on: each drawn line, the tinted zones between
    // neighbouring ones, and the lines' names.
    private let bands: SMABands?
    private let bandLines: [(level: SMABands.Level, path: Path)]
    private let zones: [(level: SMABands.Level, path: Path)]
    private let names: [(label: String, y: CGFloat)]

    private var plotBottom: CGFloat { plotHeight - 1 }

    init(series: CandleSeries, points: [Candle], bands: SMABands? = nil, size: CGSize) {
        self.points = points
        width = size.width
        height = size.height
        plotHeight = max(size.height - Self.axisHeight - Self.volumeGap - Self.volumeHeight, 20)
        let plotBottom = plotHeight - 1

        let closes = points.map(\.close)
        // Only the lines the price crosses set the scale, the average
        // included.
        let bands = bands?.average.count == points.count ? bands : nil
        self.bands = bands
        var values = closes
        if let bands {
            for level in bands.drawn where bands.crosses(level) {
                values += bands.average.compactMap { $0.map { $0 * (1 + level.offset) } }
            }
        }
        let lo = values.min() ?? 0
        let hi = values.max() ?? 0
        self.lo = lo
        self.hi = hi
        func y(_ value: Double) -> CGFloat {
            hi > lo ? plotBottom - CGFloat((value - lo) / (hi - lo)) * (plotBottom - Self.plotTop) : (Self.plotTop + plotBottom) / 2
        }
        // The guides from the top down, and the width their labels take from
        // the plot. A flat line gets neither.
        var valueTicks: [(y: CGFloat, label: String)] = []
        var columnWidth: CGFloat = 0
        if hi > lo {
            let step = (hi - lo) / Double(Self.bands)
            let format = Self.axisFormatter(hi: hi, step: step)
            valueTicks = (0..<Self.bands).map { k in
                (Self.plotTop + CGFloat(k) * (plotBottom - Self.plotTop) / CGFloat(Self.bands), format(hi - Double(k) * step))
            }
            columnWidth = CGFloat(valueTicks.map(\.label.count).max() ?? 0) * Self.charWidth + Self.axisGap
        }
        self.valueTicks = valueTicks
        // On the day, the latest price is tagged in the label column, which
        // widens to fit it.
        let tag = series.range == .day ? closes.last.map(Self.tagLabel) : nil
        self.tag = tag
        if let tag {
            columnWidth = max(columnWidth, Self.tagWidth(tag) + Self.tagGap)
        }
        // An average that ends outside the scale is named at that edge,
        // pointing the way it lies.
        let end = bands?.average.lastIndex { $0 != nil }
        let averageEnd = end.flatMap { bands?.average[$0] }
        let averageName = averageEnd.map { $0 < lo ? "SMA \u{2193}" : $0 > hi ? "SMA \u{2191}" : "SMA" } ?? "SMA"
        func name(_ level: SMABands.Level) -> String { level.isAverage ? averageName : level.label }
        let namesWidth = bands.map { CGFloat($0.drawn.map { name($0).count }.max() ?? 0) * Self.nameCharWidth + 2 * Self.nameInset } ?? 0
        let plotWidth = max(size.width - columnWidth - namesWidth, 10)
        self.plotWidth = plotWidth

        let last = max(points.count - 1, 1)
        let xs = points.indices.map { CGFloat($0) * plotWidth / CGFloat(last) }
        self.xs = xs
        ys = closes.map(y)
        timeTicks = Self.timeAxis(points.map(\.time), xs: xs, range: series.range, calendar: series.calendar, width: size.width)

        // Each line runs through the points that have an average; a point
        // without a full window behind it breaks it.
        if let bands {
            var runs: [[Int]] = []
            for (i, average) in bands.average.enumerated() where average != nil {
                if let last = runs.last?.last, last == i - 1 { runs[runs.count - 1].append(i) } else { runs.append([i]) }
            }
            func trace(_ run: [Int], _ level: SMABands.Level) -> [CGPoint] {
                run.map { CGPoint(x: xs[$0], y: y(bands.average[$0]! * (1 + level.offset))) }
            }
            bandLines = bands.drawn.map { level in
                var path = Path()
                for run in runs { path.addLines(trace(run, level)) }
                return (level, path)
            }
            // A zone is tinted only between neighbouring lines that are both
            // drawn, in the outer one's colour: the average can stand apart
            // from the bands the price reached.
            let levels = SMABands.levels
            zones = zip(bands.drawn, bands.drawn.dropFirst()).compactMap { upper, inner in
                guard let u = levels.firstIndex(of: upper), levels.firstIndex(of: inner) == u + 1 else { return nil }
                var path = Path()
                for run in runs {
                    path.addLines(trace(run, upper) + trace(run, inner).reversed())
                    path.closeSubpath()
                }
                return (abs(upper.offset) > abs(inner.offset) ? upper : inner, path)
            }
            // An off-scale name is held at the edge it lies past, so it can't
            // drag a neighbour's name away from its line.
            if let averageEnd {
                let want = bands.drawn.map { min(max(y(averageEnd * (1 + $0.offset)), Self.plotTop), plotBottom) }
                let at = Self.spread(want, gap: Self.nameGap, min: Self.plotTop + Self.nameGap / 2, max: plotBottom - Self.nameGap / 2)
                names = zip(bands.drawn, at).map { (name($0), $1) }
            } else {
                names = []
            }
        } else {
            bandLines = []
            zones = []
            names = []
        }

        // Each edge of the extended stretches midway between the session's
        // outermost point and its neighbour, on a whole point.
        let sessions = points.map(\.session)
        if sessions.contains(where: { $0 != .regular }) {
            if let open = sessions.firstIndex(of: .regular), let close = sessions.lastIndex(of: .regular) {
                regular = open...close
                var shade: [ClosedRange<CGFloat>] = []
                if open > 0 { shade.append(0...((xs[open - 1] + xs[open]) / 2).rounded()) }
                if close < xs.count - 1 { shade.append(((xs[close] + xs[close + 1]) / 2).rounded()...plotWidth) }
                self.shade = shade
            } else {
                regular = nil
                shade = [0...plotWidth]
            }
        } else {
            regular = points.isEmpty ? nil : 0...(points.count - 1)
            shade = []
        }
    }

    // The point nearest the pointer.
    func index(nearestX px: CGFloat) -> Int? {
        guard points.count > 1 else { return points.isEmpty ? nil : 0 }
        let last = points.count - 1
        return min(max(Int((px / plotWidth * CGFloat(last)).rounded()), 0), last)
    }

    private func y(_ value: Double) -> CGFloat {
        hi > lo ? plotBottom - CGFloat((value - lo) / (hi - lo)) * (plotBottom - Self.plotTop) : (Self.plotTop + plotBottom) / 2
    }

    // Every drawn line on the crosshair at point `i`, and the price among
    // them, top down: nil without the bands, or before the average begins.
    func rungs(at i: Int, colors: Colors) -> [Rung]? {
        guard let bands, points.indices.contains(i), let average = bands.average[i] else { return nil }
        let lines = bands.drawn.map {
            Rung(label: $0.label, value: average * (1 + $0.offset), color: colors.color(for: $0), kind: $0.isAverage ? .average : .band)
        }
        return (lines + [Rung(label: "Price", value: points[i].close, color: colors.accent, kind: .price)])
            .sorted { $0.value > $1.value }
    }

    // Where the ladder hangs: starting just right of the crosshair in the
    // plot's left half, ending just left of it in the right half.
    enum LadderPlace {
        case after(CGFloat), before(CGFloat)
    }

    func ladderPlace(at i: Int) -> LadderPlace? {
        guard xs.indices.contains(i) else { return nil }
        let x = xs[i]
        return x < plotWidth / 2 ? .after(x + Self.ladderGap) : .before(x - Self.ladderGap)
    }

    // The plot, where lines off the price's scale are cut off.
    private var plotClip: Path {
        Path(CGRect(x: 0, y: 0, width: plotWidth + 1, height: plotHeight))
    }

    func draw(in context: inout GraphicsContext, selection: Int?, colors: Colors) {
        let (accent, line, muted) = (colors.accent, colors.line, colors.muted)

        // The stretches before the open and after the close, recessed.
        for stretch in shade {
            let rect = CGRect(x: stretch.lowerBound, y: Self.plotTop, width: stretch.upperBound - stretch.lowerBound, height: plotHeight - Self.plotTop)
            context.fill(Path(rect), with: .color(colors.subtle))
        }

        // The value scale: a hairline at the top of each band, running under
        // the label column, its value just beneath it at the right, a rule
        // closing the plot off from the labels, and a firmer baseline the low
        // sits on.
        var grid = Path()
        for tick in valueTicks {
            grid.move(to: CGPoint(x: 0, y: tick.y))
            grid.addLine(to: CGPoint(x: width, y: tick.y))
        }
        if !valueTicks.isEmpty {
            grid.move(to: CGPoint(x: plotWidth, y: Self.plotTop))
            grid.addLine(to: CGPoint(x: plotWidth, y: plotHeight))
        }
        // The time scale: a guide where each hour, session, week, month or
        // year begins, running down through the label row.
        for tick in timeTicks {
            let x = tick.x.rounded() + 0.5
            grid.move(to: CGPoint(x: x, y: Self.plotTop))
            grid.addLine(to: CGPoint(x: x, y: plotHeight + Self.axisHeight))
        }
        context.stroke(grid, with: .color(line), lineWidth: 1)
        context.stroke(segment(CGPoint(x: 0, y: plotHeight - 0.5), CGPoint(x: width, y: plotHeight - 0.5)), with: .color(muted), lineWidth: 1)
        // The day's price tag, held inside the plot's height; a scale label
        // it would touch gives way to it.
        let tagY = tag == nil ? nil : ys.last.map { min(max($0 - Self.tagHeight / 2, 0), plotHeight - Self.tagHeight) }
        for tick in valueTicks {
            if let tagY, abs(tick.y + Self.labelMid - (tagY + Self.tagHeight / 2)) < Self.tagHeight / 2 + Self.labelHalf { continue }
            context.draw(Text(tick.label).font(Self.labelFont).foregroundStyle(.primary), at: CGPoint(x: width, y: tick.y + 2), anchor: .topTrailing)
        }
        for tick in timeTicks {
            context.draw(
                Text(tick.label).font(Self.labelFont).foregroundStyle(.primary),
                at: CGPoint(x: tick.x + Self.labelInset, y: plotHeight + Self.axisHeight / 2),
                anchor: .leading
            )
        }
        if let tag, let tagY {
            let tagWidth = Self.tagWidth(tag)
            let rect = CGRect(x: width - tagWidth, y: tagY, width: tagWidth, height: Self.tagHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(accent))
            context.draw(
                Text(tag).font(Self.labelFont.weight(.semibold)).foregroundStyle(colors.background),
                at: CGPoint(x: width - Self.tagPadding, y: rect.midY),
                anchor: .trailing
            )
        }

        // Volume: grey strokes rising from the strip's floor, scaled to the
        // busiest bar. Bars nearer than 3pt are summed, so a decade of weeks
        // reads as a texture rather than a solid block.
        var strokes: [(x: CGFloat, volume: Double)] = []
        for (x, point) in zip(xs, points) {
            if let last = strokes.last, x - last.x < 3 {
                strokes[strokes.count - 1].volume += point.volume ?? 0
            } else {
                strokes.append((x, point.volume ?? 0))
            }
        }
        if let busiest = strokes.map(\.volume).max(), busiest > 0 {
            var volume = Path()
            for stroke in strokes where stroke.volume > 0 {
                volume.move(to: CGPoint(x: stroke.x, y: height))
                volume.addLine(to: CGPoint(x: stroke.x, y: height - max(1, CGFloat(stroke.volume / busiest) * Self.volumeHeight)))
            }
            context.stroke(volume, with: .color(muted), lineWidth: 1.5)
        }

        guard points.count > 1 else { return }
        let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        // The bands' tints replace the price's fill, rather than mix with it.
        if !zones.isEmpty {
            context.drawLayer { layer in
                layer.clip(to: plotClip)
                for zone in zones {
                    layer.fill(zone.path, with: .color(colors.color(for: zone.level).opacity(Self.tint(zone.level))))
                }
            }
        } else if let regular, regular.count > 1 {
            // The fill fades down from the line, under the regular session only.
            var fill = path(regular)
            fill.addLine(to: CGPoint(x: xs[regular.upperBound], y: plotBottom))
            fill.addLine(to: CGPoint(x: xs[regular.lowerBound], y: plotBottom))
            fill.closeSubpath()
            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [accent.opacity(0.24), accent.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: Self.plotTop),
                    endPoint: CGPoint(x: 0, y: plotBottom)
                )
            )
        }
        // The average, dashed, and the bands about it, under the price.
        if !bandLines.isEmpty {
            context.drawLayer { layer in
                layer.clip(to: plotClip)
                for line in bandLines {
                    let style = line.level.isAverage
                        ? StrokeStyle(lineWidth: 1.5, lineJoin: .round, dash: Self.averageDash)
                        : StrokeStyle(lineWidth: 1, lineJoin: .round)
                    layer.stroke(line.path, with: .color(colors.color(for: line.level)), style: style)
                }
            }
        }
        // Each line's name, haloed to clear the scale's hairlines: cut out of
        // what's drawn, down to the glass behind.
        for name in names {
            let halo = CGRect(x: plotWidth + Self.nameInset - 2, y: name.y - 5.5, width: CGFloat(name.label.count) * Self.nameCharWidth + 4, height: 11)
            Self.cutOut(Path(halo), in: &context)
            context.draw(
                Text(name.label).font(Self.nameFont).foregroundStyle(colors.secondary),
                at: CGPoint(x: plotWidth + Self.nameInset, y: name.y),
                anchor: .leading
            )
        }
        // Faded where it runs through extended hours, the regular session
        // drawn over it at full strength.
        if shade.isEmpty {
            context.stroke(path(points.indices), with: .color(accent), style: style)
        } else {
            context.stroke(path(points.indices), with: .color(accent.opacity(Self.extendedOpacity)), style: style)
            if let regular { context.stroke(path(regular), with: .color(accent), style: style) }
        }
        // The latest price, full strength wherever it falls.
        if let x = xs.last, let y = ys.last {
            context.fill(dot(x, y, 3), with: .color(accent))
        }

        // The pick: a dashed guide down the plot and a ringed dot on the line.
        if let i = selection, points.indices.contains(i) {
            context.stroke(
                segment(CGPoint(x: xs[i], y: 0), CGPoint(x: xs[i], y: plotHeight)),
                with: .color(muted), style: StrokeStyle(lineWidth: 1, dash: [2, 3])
            )
            // A dot where it crosses each drawn line; one off the scale is
            // cut off, though the ladder still lists it.
            if let bands, let average = bands.average[i] {
                context.drawLayer { layer in
                    layer.clip(to: plotClip)
                    for level in bands.drawn {
                        layer.fill(dot(xs[i], y(average * (1 + level.offset)), 2.5), with: .color(colors.color(for: level)))
                    }
                }
            }
            Self.cutOut(dot(xs[i], ys[i], 3.5).strokedPath(StrokeStyle(lineWidth: 4)), in: &context)
            context.fill(dot(xs[i], ys[i], 3.5), with: .color(accent))
        }
    }

    // Clears `path` of everything drawn so far, so the popover's surface
    // shows through: a halo that works over glass, as a fill in a fixed
    // colour wouldn't.
    private static func cutOut(_ path: Path, in context: inout GraphicsContext) {
        var eraser = context
        eraser.blendMode = .destinationOut
        eraser.fill(path, with: .color(.black))
    }

    // The line through the points in `indices`.
    private func path<R: Sequence<Int>>(_ indices: R) -> Path {
        var path = Path()
        path.addLines(indices.map { CGPoint(x: xs[$0], y: ys[$0]) })
        return path
    }

    private func segment(_ a: CGPoint, _ b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }

    private func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }

    // Few enough digits to read at a glance, enough that neighbours differ:
    // 241 / 222 / 202, 63.1K / 62.8K, 0.0123.
    private static func axisFormatter(hi: Double, step: Double) -> (Double) -> String {
        let magnitude = abs(hi)
        let (unit, suffix): (Double, String) = magnitude >= 1e6 ? (1e6, "M") : magnitude >= 1e4 ? (1e3, "K") : (1, "")
        let digits = min(unit > 1 ? 2 : 4, max(0, Int(ceil(-log10(step / unit)))))
        return { ($0 / unit).formatted(.number.precision(.fractionLength(digits))) + suffix }
    }

    // The tag's price, to its own precision and without the currency (the
    // scale has none): whole above a thousand, cents above one, four places
    // below. "15,038", "350.88", "0.9451".
    private static func tagLabel(_ price: Double) -> String {
        let digits = abs(price) >= 1000 ? 0 : abs(price) >= 1 ? 2 : 4
        return price.formatted(.number.precision(.fractionLength(digits)))
    }

    private static func tagWidth(_ label: String) -> CGFloat {
        CGFloat(label.count) * charWidth + 2 * tagPadding
    }

    // Heights for labels that want the given ones (top down), at least `gap`
    // apart and within min…max: each run that would overlap is spaced out
    // about its own centre.
    private static func spread(_ want: [CGFloat], gap: CGFloat, min lower: CGFloat, max upper: CGFloat) -> [CGFloat] {
        func place(_ n: Int, _ sum: CGFloat) -> CGFloat {
            min(max(sum / CGFloat(n) - CGFloat(n - 1) * gap / 2, lower), upper - CGFloat(n - 1) * gap)
        }
        var groups: [(n: Int, sum: CGFloat, top: CGFloat)] = []
        for y in want {
            var group = (n: 1, sum: y, top: place(1, y))
            // Merge back while the run above reaches into this one.
            while let previous = groups.last, previous.top + CGFloat(previous.n) * gap > group.top {
                groups.removeLast()
                let n = previous.n + group.n, sum = previous.sum + group.sum
                group = (n, sum, place(n, sum))
            }
            groups.append(group)
        }
        return groups.flatMap { group in (0..<group.n).map { group.top + CGFloat($0) * gap } }
    }

    // A guide where each hour (1D), session (1W), week (1M), month (3M, 6M,
    // 1Y) or year (2Y, 5Y, All) begins, its name just right of it: "30 · 2 ·
    // 3 · 4 · 5" across a week. When they crowd (a year's twelve months, a
    // decade's years), every second or third is kept, evenly. A unit that
    // begins on the last point spans nothing, so it gets no guide. A day
    // that runs over two dates names the second where it begins ("Fri"),
    // and that name is always kept, the hours beside it giving way.
    private static func timeAxis(_ times: [Date], xs: [CGFloat], range: ChartRange, calendar: Calendar, width: CGFloat) -> [(x: CGFloat, label: String)] {
        let hour: TimeInterval = 3600
        // A week is cut into sessions by its overnight gaps rather than by
        // date, so a session that crosses midnight reads as one day; one
        // that never pauses (crypto) is cut at midnight.
        let pauses = zip(times, times.dropFirst()).contains { $1.timeIntervalSince($0) > 2 * hour }
        var monthStyle = Date.FormatStyle().month(.abbreviated)
        monthStyle.timeZone = calendar.timeZone
        func day(_ d: Date) -> String { String(calendar.component(.day, from: d)) }
        // "9", "10" … "1": the hour as the reader's clock numbers it.
        func clockHour(_ d: Date) -> String {
            let h = calendar.component(.hour, from: d)
            return String(Clock.twelveHour ? (h + 11) % 12 + 1 : h)
        }

        var weekdayStyle = Date.FormatStyle().weekday(.abbreviated)
        weekdayStyle.timeZone = calendar.timeZone

        func label(_ i: Int) -> String? {
            let d = times[i]
            guard i > 0 else {
                switch range {
                case .day: return calendar.component(.minute, from: d) == 0 ? clockHour(d) : nil
                case .week: return day(d)
                default: return nil // a range rarely opens on a week, month or year
                }
            }
            let prev = times[i - 1]
            switch range {
            case .day:
                if !calendar.isDate(d, inSameDayAs: prev) { return d.formatted(weekdayStyle) }
                return calendar.component(.hour, from: d) != calendar.component(.hour, from: prev) ? clockHour(d) : nil
            case .week:
                let starts = pauses ? d.timeIntervalSince(prev) > 2 * hour : !calendar.isDate(d, inSameDayAs: prev)
                return starts ? day(d) : nil
            case .month:
                let weekday = { (calendar.component(.weekday, from: $0) + 5) % 7 } // Monday 0
                return weekday(d) < weekday(prev) || d.timeIntervalSince(prev) >= 7 * 24 * hour ? day(d) : nil
            case .threeMonths, .sixMonths, .year:
                return calendar.component(.month, from: d) != calendar.component(.month, from: prev) ? d.formatted(monthStyle) : nil
            case .twoYears, .fiveYears, .all:
                let year = calendar.component(.year, from: d)
                return year != calendar.component(.year, from: prev) ? String(year) : nil
            }
        }

        // A new day's name, on the day's chart, is kept whatever else goes.
        var days: [(x: CGFloat, label: String)] = []
        var ticks: [(x: CGFloat, label: String)] = []
        for i in times.indices.dropLast() {
            guard let text = label(i) else { continue }
            if range == .day, i > 0, !calendar.isDate(times[i], inSameDayAs: times[i - 1]) {
                days.append((xs[i], text))
            } else {
                ticks.append((xs[i], text))
            }
        }
        let room = CGFloat((ticks + days).map(\.label.count).max() ?? 0) * charWidth + 2 * labelInset
        var every = 1
        while ticks.indices.contains(where: { $0 >= every && $0 % every == 0 && ticks[$0].x - ticks[$0 - every].x < room }) {
            every += 1
        }
        let kept = ticks.indices
            .filter { i in i % every == 0 && !days.contains { abs($0.x - ticks[i].x) < room } }
            .map { ticks[$0] }
        return (kept + days)
            .filter { $0.x + labelInset + CGFloat($0.label.count) * charWidth <= width }
            .sorted { $0.x < $1.x }
    }
}

// The line as VoiceOver and its audio graph read it: one data point a point,
// named with its session outside the regular one.
struct LineChartDescriptor: AXChartDescriptorRepresentable {
    let series: CandleSeries
    let points: [Candle]
    // The 200-day average at each point, with the SMA bands on.
    var average: [Double?]?

    func makeChartDescriptor() -> AXChartDescriptor {
        let labels = points.map { CandleText.when($0, span: series.lineSpan, in: series) }
        let closes = points.map(\.close)
        let values = closes + (average ?? []).compactMap { $0 }
        let low = values.min() ?? 0
        let high = max(values.max() ?? 1, low + 0.01)
        let decimals = series.decimals
        let x = AXCategoricalDataAxisDescriptor(title: "Time", categoryOrder: labels)
        let y = AXNumericDataAxisDescriptor(title: "Price", range: low...high, gridlinePositions: []) {
            PriceFormat.price($0, decimals: decimals)
        }
        let data = zip(labels, points).map { label, point in
            AXDataPoint(x: label, y: point.close, additionalValues: [], label: PriceFormat.price(point.close, decimals: decimals))
        }
        return AXChartDescriptor(
            title: "\(series.symbol) \(series.range.phrase)",
            summary: nil,
            xAxis: x,
            yAxis: y,
            additionalAxes: [],
            series: [AXDataSeriesDescriptor(name: "Price", isContinuous: true, dataPoints: data)]
                + (average.map { average in
                    let points = zip(labels, average).compactMap { label, value in
                        value.map { AXDataPoint(x: label, y: $0, additionalValues: [], label: PriceFormat.price($0, decimals: decimals)) }
                    }
                    return [AXDataSeriesDescriptor(name: "200-day average", isContinuous: true, dataPoints: points)]
                } ?? [])
        )
    }
}
