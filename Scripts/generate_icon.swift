import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_icon.swift OUTPUT.png\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let pixelSize = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelSize,
    pixelsHigh: pixelSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("failed to create bitmap context\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
defer { NSGraphicsContext.restoreGraphicsState() }

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill()

let iconRect = NSRect(x: 92, y: 92, width: 840, height: 840)
let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 190, yRadius: 190)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 34
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.14, alpha: 1).setFill()
iconPath.fill()
NSGraphicsContext.restoreGraphicsState()

let screenRect = NSRect(x: 164, y: 220, width: 696, height: 580)
let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 54, yRadius: 54)
NSColor(calibratedRed: 0.15, green: 0.17, blue: 0.19, alpha: 1).setFill()
screenPath.fill()

let toolbarPath = NSBezierPath(roundedRect: NSRect(x: 164, y: 690, width: 696, height: 110), xRadius: 54, yRadius: 54)
NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.24, alpha: 1).setFill()
toolbarPath.fill()
NSRect(x: 164, y: 690, width: 696, height: 55).fill()

let dots: [(NSColor, CGFloat)] = [
    (NSColor(calibratedRed: 0.95, green: 0.34, blue: 0.29, alpha: 1), 222),
    (NSColor(calibratedRed: 0.96, green: 0.72, blue: 0.20, alpha: 1), 282),
    (NSColor(calibratedRed: 0.18, green: 0.72, blue: 0.43, alpha: 1), 342)
]
for (color, x) in dots {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: x, y: 728, width: 28, height: 28)).fill()
}

let promptAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 178, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.24, green: 0.84, blue: 0.55, alpha: 1)
]
let prompt = NSString(string: "$")
prompt.draw(at: NSPoint(x: 226, y: 410), withAttributes: promptAttributes)

let equalsAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 150, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.28, alpha: 1)
]
NSString(string: "=").draw(at: NSPoint(x: 430, y: 428), withAttributes: equalsAttributes)

NSColor(calibratedRed: 0.95, green: 0.36, blue: 0.31, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 602, y: 438, width: 158, height: 38), xRadius: 19, yRadius: 19).fill()
NSColor(calibratedRed: 0.45, green: 0.50, blue: 0.54, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 226, y: 322, width: 534, height: 26), xRadius: 13, yRadius: 13).fill()

context.flushGraphics()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("failed to render icon\n", stderr)
    exit(1)
}

try png.write(to: outputURL, options: .atomic)
