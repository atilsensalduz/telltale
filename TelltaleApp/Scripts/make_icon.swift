#!/usr/bin/env swift
// Draws the Telltale app icon and writes Resources/AppIcon.icns.
// Usage: swift Scripts/make_icon.swift   (run from TelltaleApp/; needs iconutil, which ships with macOS)
//
// The icon is a dark squircle holding a latency trace that settles into a green "all good" light:
// the same idea as the menu bar glyph and the popover chart.
import AppKit

let canvas: CGFloat = 1024

func draw(into ctx: CGContext) {
    let space = CGColorSpaceCreateDeviceRGB()
    func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
    }

    // macOS icon grid: an 824 pt body centred on the 1024 pt canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 190, cornerHeight: 190, transform: nil)

    // Soft drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.setFillColor(rgb(20, 24, 32))
    ctx.addPath(bodyPath)
    ctx.fillPath()
    ctx.restoreGState()

    // Body gradient.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space,
                        colors: [rgb(46, 54, 70), rgb(16, 19, 27)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // A faint baseline grid, like the chart in the popover.
    ctx.setStrokeColor(rgb(255, 255, 255, 0.05))
    ctx.setLineWidth(4)
    for y in stride(from: 250 as CGFloat, through: 780, by: 132) {
        ctx.move(to: CGPoint(x: 100, y: y))
        ctx.addLine(to: CGPoint(x: 924, y: y))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // Hairline highlight around the edge.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.12))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // Latency trace: calm, one spike, then steady into the light.
    let trace = CGMutablePath()
    trace.move(to: CGPoint(x: 190, y: 500))
    trace.addLine(to: CGPoint(x: 320, y: 500))
    trace.addLine(to: CGPoint(x: 385, y: 650))
    trace.addLine(to: CGPoint(x: 465, y: 340))
    trace.addLine(to: CGPoint(x: 540, y: 540))
    trace.addLine(to: CGPoint(x: 590, y: 500))
    trace.addLine(to: CGPoint(x: 690, y: 500))

    ctx.saveGState()
    ctx.addPath(trace)
    ctx.setLineWidth(40)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let fade = CGGradient(colorsSpace: space,
                          colors: [rgb(255, 255, 255, 0.3), rgb(255, 255, 255, 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fade, start: CGPoint(x: 190, y: 0), end: CGPoint(x: 520, y: 0),
                           options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    // The light: glow, ring, core.
    let centre = CGPoint(x: 755, y: 500)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70, color: rgb(52, 199, 89, 0.9))
    ctx.setFillColor(rgb(52, 199, 89))
    ctx.fillEllipse(in: CGRect(x: centre.x - 58, y: centre.y - 58, width: 116, height: 116))
    ctx.restoreGState()

    ctx.setStrokeColor(rgb(52, 199, 89, 0.35))
    ctx.setLineWidth(14)
    ctx.strokeEllipse(in: CGRect(x: centre.x - 96, y: centre.y - 96, width: 192, height: 192))

    let core = CGGradient(colorsSpace: space,
                          colors: [rgb(140, 240, 168), rgb(40, 180, 78)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: centre.x - 58, y: centre.y - 58, width: 116, height: 116))
    ctx.clip()
    ctx.drawLinearGradient(core, start: CGPoint(x: centre.x, y: centre.y + 58),
                           end: CGPoint(x: centre.x, y: centre.y - 58), options: [])
    ctx.restoreGState()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    gc.imageInterpolation = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    draw(into: ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("Telltale-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try png(pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
// A full-size preview next to the .icns, handy for README or a quick look.
try png(pixels: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote Resources/AppIcon.icns and Resources/AppIcon.png")
