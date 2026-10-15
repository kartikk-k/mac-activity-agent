import SwiftUI
import AppKit

/// Fixed-dimensional values give SwiftUI a real interpolation space even as samples arrive.
private struct GraphVector: VectorArithmetic {
    static let count = 64
    var values: [Double]
    static var zero: GraphVector { GraphVector(values: Array(repeating: 0, count: count)) }
    static func + (lhs: Self, rhs: Self) -> Self {
        Self(values: zip(lhs.values, rhs.values).map(+))
    }
    static func - (lhs: Self, rhs: Self) -> Self {
        Self(values: zip(lhs.values, rhs.values).map(-))
    }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
    static func resampling(_ source: [Double], ceiling: Double) -> Self {
        guard !source.isEmpty else { return .zero }
        let upper = ceiling.isFinite && ceiling > 0 ? ceiling : 100
        func normalized(_ value: Double) -> Double { value.isFinite ? max(0, min(1, value / upper)) : 0 }
        return Self(values: (0..<count).map { index in
            let position = Double(index) * Double(source.count - 1) / Double(count - 1)
            let low = Int(position), high = min(source.count - 1, low + 1)
            let weight = position - Double(low)
            return normalized(source[low]) * (1 - weight) + normalized(source[high]) * weight
        })
    }
}

/// Interpolates only during a finite update; idle/background charts have no animation loop.
struct DotPlot: View {
    var values: [Double]
    var color: Color = .primary
    var ceiling: Double = 100
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let vector = GraphVector.resampling(values, ceiling: ceiling)
        DotPlotRenderer(vector: vector, color: color, hasSamples: !values.isEmpty)
            .animation(reduceMotion || scenePhase != .active || !NSApp.isActive ? nil : .easeInOut(duration: 0.4), value: vector)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Activity graph")
            .accessibilityValue(values.last.map { String(format: "Latest value %.1f", $0) } ?? "No samples yet")
    }
}

private struct DotPlotRenderer: View, Animatable {
    var vector: GraphVector
    var color: Color
    var hasSamples: Bool
    var animatableData: GraphVector {
        get { vector }
        set { vector = newValue }
    }
    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 3
            let width = max(0, size.width - inset * 2)
            let height = max(0, size.height - inset * 2)
            guard width > 0, height > 0 else { return }
            let columns = max(2, min(72, Int(width / 9)))
            let rows = max(2, min(12, Int(height / 10)))
            var grid = Path()
            for row in 0...rows {
                for column in 0...columns {
                    let center = CGPoint(x: inset + width * CGFloat(column) / CGFloat(columns), y: inset + height * CGFloat(row) / CGFloat(rows))
                    grid.addEllipse(in: CGRect(x: center.x - 0.65, y: center.y - 0.65, width: 1.3, height: 1.3))
                }
            }
            context.fill(grid, with: .color(color.opacity(0.13)))
            let samples = vector.values
            guard hasSamples else { return }
            let upper = 1.0
            func point(_ index: Int) -> CGPoint {
                let value = samples[index].isFinite ? max(0, min(upper, samples[index])) : 0
                return CGPoint(x: inset + width * CGFloat(index) / CGFloat(max(1, samples.count - 1)), y: inset + height * CGFloat(1 - value / upper))
            }
            var trace = Path()
            // Place circles at a fixed arc-length spacing, including on steep segments.
            var distanceToNext: CGFloat = 0
            if samples.count == 1 {
                let p = point(0)
                trace.addEllipse(in: CGRect(x: p.x - 1.4, y: p.y - 1.4, width: 2.8, height: 2.8))
            } else {
                for index in 1..<samples.count {
                    let from = point(index - 1), to = point(index)
                    let dx = to.x - from.x, dy = to.y - from.y
                    let length = hypot(dx, dy)
                    guard length > 0 else { continue }
                    var offset = distanceToNext
                    while offset <= length {
                        let t = offset / length
                        let p = CGPoint(x: from.x + dx * t, y: from.y + dy * t)
                        trace.addEllipse(in: CGRect(x: p.x - 1.35, y: p.y - 1.35, width: 2.7, height: 2.7))
                        offset += 5
                    }
                    distanceToNext = offset - length
                }
            }
            context.fill(trace, with: .color(color.opacity(0.82)))
            if let last = samples.indices.last {
                let p = point(last)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(color))
            }
        }
    }
}

struct NativeWindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowMaterialView {
        let view = WindowMaterialView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.autoresizingMask = [.width, .height]
        return view
    }
    func updateNSView(_ view: WindowMaterialView, context: Context) { view.configureWindow() }
}

final class WindowMaterialView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }
    func configureWindow() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
    }
    // The background should never intercept clicks intended for SwiftUI controls.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A bounded, native trend that interpolates for 0.4 seconds when foreground data changes.
struct SoftTrendGraph: View {
    var values: [Double]
    var color: Color = .primary
    var ceiling: Double = 100
    var showsRange: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let vector = GraphVector.resampling(values, ceiling: ceiling)
        SoftTrendRenderer(vector: vector, color: color, showsRange: showsRange, hasSamples: !values.isEmpty)
            .animation(reduceMotion || scenePhase != .active || !NSApp.isActive ? nil : .easeInOut(duration: 0.4), value: vector)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(showsRange ? "Historical activity trend" : "Activity trend")
            .accessibilityValue(values.last.map { String(format: "Latest value %.1f", $0) } ?? "No samples yet")
    }
}

private struct SoftTrendRenderer: View, Animatable {
    var vector: GraphVector
    var color: Color
    var showsRange: Bool
    var hasSamples: Bool
    @Environment(\.colorScheme) private var colorScheme
    var animatableData: GraphVector {
        get { vector }
        set { vector = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let data = vector.values
            guard hasSamples, size.width > 4, size.height > 4 else { return }
            let dark = colorScheme == .dark
            let padding: CGFloat = 2
            let width = size.width - padding * 2
            let height = size.height - padding * 2
            let upper = 1.0
            let points = data.enumerated().map { index, value in
                CGPoint(x: padding + width * CGFloat(index) / CGFloat(max(1, data.count - 1)),
                        y: padding + height * CGFloat(1 - max(0, min(upper, value.isFinite ? value : 0)) / upper))
            }
            guard let first = points.first, let last = points.last else { return }
            var line = Path()
            line.move(to: first)
            if points.count == 1 {
                line.addLine(to: CGPoint(x: padding + width, y: first.y))
            } else {
                // Midpoint quadratics smooth the trace without overshooting samples.
                for index in 1..<points.count {
                    let before = points[index - 1], next = points[index]
                    let midpoint = CGPoint(x: (before.x + next.x) / 2, y: (before.y + next.y) / 2)
                    line.addQuadCurve(to: midpoint, control: before)
                }
                line.addQuadCurve(to: last, control: last)
            }
            var fill = line
            fill.addLine(to: CGPoint(x: points.count == 1 ? size.width - padding : last.x, y: size.height))
            fill.addLine(to: CGPoint(x: first.x, y: size.height))
            fill.closeSubpath()
            let wash = Gradient(stops: [
                .init(color: Color(red: 0.70, green: 0.80, blue: 0.95).opacity(dark ? 0.25 : 0.31), location: 0),
                .init(color: Color(red: 0.78, green: 0.75, blue: 0.92).opacity(dark ? 0.12 : 0.15), location: 0.42),
                .init(color: Color(red: 0.94, green: 0.90, blue: 0.73).opacity(dark ? 0.055 : 0.075), location: 0.74),
                .init(color: .clear, location: 1)
            ])
            context.fill(fill, with: .linearGradient(wash, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            if showsRange {
                // A very faint baseline gives longer history plots a little orientation.
                var baseline = Path()
                baseline.move(to: CGPoint(x: padding, y: size.height - padding))
                baseline.addLine(to: CGPoint(x: size.width - padding, y: size.height - padding))
                context.stroke(baseline, with: .color(color.opacity(0.07)), lineWidth: 0.5)
            }
            context.stroke(line, with: .color(color.opacity(dark ? 0.86 : 0.67)), style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
            let markerX = points.count == 1 ? size.width - padding : last.x
            var marker = Path()
            marker.move(to: CGPoint(x: markerX, y: padding))
            marker.addLine(to: CGPoint(x: markerX, y: size.height - padding))
            let markerColor = dark ? Color(red: 0.82, green: 0.88, blue: 0.64) : Color(red: 0.49, green: 0.56, blue: 0.27)
            context.stroke(marker, with: .color(markerColor.opacity(0.65)), lineWidth: 0.65)
        }
    }
}
