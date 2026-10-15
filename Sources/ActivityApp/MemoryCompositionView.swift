import SwiftUI
import AppKit

/// Three rows of memory dots, with bounded interpolation only when readings change.
struct MemoryDotBar: View {
    let total: UInt64
    let used: UInt64
    let wired: UInt64
    let compressed: UInt64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let denominator = max(1, Double(total))
        let usedFraction = min(1, Double(used) / denominator)
        let wiredFraction = min(usedFraction, Double(wired) / denominator)
        let compressedEnd = min(usedFraction, wiredFraction + Double(compressed) / denominator)
        let fractions = AnimatablePair(usedFraction, AnimatablePair(wiredFraction, compressedEnd))
        MemoryDotRenderer(fractions: fractions)
            .animation(reduceMotion || scenePhase != .active || !NSApp.isActive ? nil : .easeInOut(duration: 0.35), value: fractions)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Memory composition")
            .accessibilityValue("\(formatted(used)) used of \(formatted(total))")
    }

    private func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}

private struct MemoryDotRenderer: View, Animatable {
    var fractions: AnimatablePair<Double, AnimatablePair<Double, Double>>
    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { fractions }
        set { fractions = newValue }
    }

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let columns = max(1, Int(size.width / 9))
            let used = fractions.first
            let wired = fractions.second.first
            let compressedEnd = fractions.second.second
            // Most dots share one of four opacity levels; only the three moving
            // boundaries need intermediate levels. Batch display-list commands
            // instead of issuing a separate fill for every dot on every frame.
            var paths: [Double: Path] = [:]
            paths.reserveCapacity(7)
            for column in 0..<columns {
                // Each dot covers one column interval. A boundary passing through
                // that interval blends its opacity instead of snapping a whole dot.
                func coverage(_ boundary: Double) -> Double {
                    min(1, max(0, boundary * Double(columns) - Double(column)))
                }
                let opacity = 0.09 + 0.26 * coverage(used)
                    + 0.25 * coverage(compressedEnd) + 0.30 * coverage(wired)
                for row in 0..<3 {
                    let x = CGFloat(column) * size.width / CGFloat(columns) + 3
                    let y = CGFloat(row) * 10 + 5
                    paths[opacity, default: Path()].addEllipse(in: CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
            for (opacity, path) in paths {
                context.fill(path, with: .color(.primary.opacity(opacity)))
            }
        }
    }
}
