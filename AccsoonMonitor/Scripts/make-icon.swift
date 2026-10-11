// Draws the app icon and writes Resources/AppIcon.icns.
// Run from the AccsoonMonitor folder: swift Scripts/make-icon.swift
import AppKit
import CoreGraphics
import Foundation

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: s, y: s)
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [r, g, b, a])!
    }
    func gradient(_ colors: [CGColor]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    }

    // Tile: the standard macOS rounded square with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.45))
    context.addPath(tilePath)
    context.setFillColor(color(0.07, 0.08, 0.10))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.drawLinearGradient(gradient([color(0.17, 0.19, 0.24), color(0.05, 0.06, 0.08)]),
                               start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    context.restoreGState()

    // Screen: a 16:9 picture in false-colour style bands.
    let screen = CGRect(x: 212, y: 300, width: 600, height: 338)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: 26, cornerHeight: 26, transform: nil)
    context.saveGState()
    context.addPath(screenPath)
    context.clip()
    context.drawLinearGradient(
        gradient([color(0.10, 0.25, 0.85), color(0.05, 0.65, 0.80), color(0.20, 0.75, 0.30),
                  color(1.0, 0.85, 0.15), color(1.0, 0.45, 0.10)]),
        start: CGPoint(x: screen.minX, y: screen.minY), end: CGPoint(x: screen.maxX, y: screen.maxY), options: [])
    // Rule-of-thirds grid.
    context.setStrokeColor(color(1, 1, 1, 0.75))
    context.setLineWidth(6)
    for t in [CGFloat(1) / 3, CGFloat(2) / 3] {
        context.move(to: CGPoint(x: screen.minX + screen.width * t, y: screen.minY))
        context.addLine(to: CGPoint(x: screen.minX + screen.width * t, y: screen.maxY))
        context.move(to: CGPoint(x: screen.minX, y: screen.minY + screen.height * t))
        context.addLine(to: CGPoint(x: screen.maxX, y: screen.minY + screen.height * t))
    }
    context.strokePath()
    context.restoreGState()

    // Bezel.
    context.addPath(CGPath(roundedRect: screen.insetBy(dx: -14, dy: -14), cornerWidth: 38, cornerHeight: 38, transform: nil))
    context.setStrokeColor(color(0.93, 0.94, 0.96))
    context.setLineWidth(28)
    context.strokePath()

    // Wireless arcs above the screen.
    let origin = CGPoint(x: 512, y: 700)
    context.setLineCap(.round)
    context.setStrokeColor(color(0.93, 0.94, 0.96))
    context.setLineWidth(26)
    for radius in [CGFloat(62), 122] {
        context.addArc(center: origin, radius: radius, startAngle: .pi * 0.25, endAngle: .pi * 0.75, clockwise: false)
        context.strokePath()
    }
    context.setFillColor(color(0.93, 0.94, 0.96))
    context.fillEllipse(in: CGRect(x: origin.x - 20, y: origin.y - 20, width: 40, height: 40))

    return context.makeImage()!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let rep = NSBitmapImageRep(cgImage: drawIcon(size: points * scale))
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
