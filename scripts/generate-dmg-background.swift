#!/usr/bin/env swift
import AppKit

// Native Finder backgrounds use points; include both 1x and 2x representations.
guard CommandLine.arguments.count == 3,
      let landscape = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fatalError("Usage: generate-dmg-background.swift sunset.webp background.tiff")
}
let size = NSSize(width: 720, height: 440)
let image = NSImage(size: size)
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
        pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let canvas = NSRect(origin: .zero, size: size)
    NSColor.white.setFill()
    canvas.fill()
    let panel = NSRect(x: 24, y: 24, width: 672, height: 392)
    let outline = NSBezierPath(roundedRect: panel, xRadius: 14, yRadius: 14)
    NSGraphicsContext.saveGraphicsState()
    outline.addClip()
    NSColor(calibratedRed: 1, green: 0.985, blue: 0.965, alpha: 1).setFill()
    panel.fill()
    let factor = max(panel.width / landscape.size.width, panel.height / landscape.size.height)
    let drawnSize = NSSize(width: landscape.size.width * factor, height: landscape.size.height * factor)
    landscape.draw(
        in: NSRect(x: panel.midX - drawnSize.width / 2, y: panel.midY - drawnSize.height / 2,
                   width: drawnSize.width, height: drawnSize.height),
        from: .zero, operation: .sourceOver, fraction: 0.24
    )
    NSGraphicsContext.restoreGraphicsState()
    NSColor(calibratedRed: 0.45, green: 0.32, blue: 0.26, alpha: 0.10).setStroke()
    outline.lineWidth = 0.5
    outline.stroke()
    // Align the chevrons with the centers of Finder's two draggable icons.
    for index in 0..<5 {
        let x = CGFloat(314 + index * 21)
        let y = size.height - 210
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: x, y: y + 7))
        arrow.line(to: NSPoint(x: x + 6, y: y))
        arrow.line(to: NSPoint(x: x, y: y - 7))
        arrow.lineWidth = 2.5
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        NSColor(calibratedRed: 0.38, green: 0.29, blue: 0.25,
                alpha: 0.15 + CGFloat(index) * 0.13).setStroke()
        arrow.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    image.addRepresentation(bitmap)
}
try image.tiffRepresentation!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
