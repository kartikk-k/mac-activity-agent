#!/usr/bin/env swift
import AppKit
import Foundation

// An original monochrome dot-matrix pulse. Render vectors at every required size.
let manager = FileManager.default
let working = URL(fileURLWithPath: manager.currentDirectoryPath)
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : working.appendingPathComponent("build/Activity Agent.app/Contents/Resources/ActivityAgent.icns")
let iconset = working.appendingPathComponent("build/IconAssets/ActivityAgent.iconset")
try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

func png(pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let shell = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 202, yRadius: 202)
    NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
    shell.fill()
    let gradient = NSGradient(starting: NSColor(calibratedWhite: 0.19, alpha: 1), ending: NSColor(calibratedWhite: 0.075, alpha: 1))!
    gradient.draw(in: shell, angle: -90)
    shell.lineWidth = 3
    NSColor(calibratedWhite: 1, alpha: 0.15).setStroke()
    shell.stroke()

    // Pulse coordinates in a 15 x 15 grid. Kept legible at Dock and Finder sizes.
    let pulse: [(Int, Int)] = [(0,7),(1,7),(2,7),(3,7),(4,8),(5,10),(6,12),(7,9),(8,4),(9,2),(10,5),(11,7),(12,7),(13,7),(14,7)]
    let lit = Set(pulse.map { "\($0.0),\($0.1)" })
    let gridStart: CGFloat = 204, step: CGFloat = 44
    for row in 0..<15 {
        for column in 0..<15 {
            let active = lit.contains("\(column),\(row)")
            // Hide the quiet grid at tiny sizes so the pulse stays recognizable.
            if !active && pixels <= 32 { continue }
            let radius: CGFloat = active ? 14 : 4
            let x = gridStart + CGFloat(column) * step
            let y = gridStart + CGFloat(row) * step
            NSColor(calibratedWhite: active ? 0.94 : 0.6, alpha: active ? 1 : 0.32).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "IconGeneration", code: 1) }
    return data
}
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(base)x\(base)\(suffix).png"
        try png(pixels: base * scale).write(to: iconset.appendingPathComponent(name))
    }
}
let command = Process()
command.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
command.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try command.run()
command.waitUntilExit()
guard command.terminationStatus == 0 else { throw NSError(domain: "IconGeneration", code: Int(command.terminationStatus)) }
print(output.path)
