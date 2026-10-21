#!/usr/bin/swift
import AppKit
import CoreImage
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Resim/Resources/Brand/Resim.icon")
let destination = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? root.appendingPathComponent("Resim/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func output(_ executable: URL, arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("\(executable.lastPathComponent) failed with exit code \(process.terminationStatus)")
    }
    return data
}
let selected = try output(URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["-p"])
let developer = URL(fileURLWithPath: String(decoding: selected, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
let renderer = developer.deletingLastPathComponent()
    .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool")
guard FileManager.default.isExecutableFile(atPath: renderer.path) else {
    fatalError("Regenerating the icon requires Icon Composer from Xcode 27.")
}
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("resim-icon-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let rendered = temporary.appendingPathComponent("rendered.png")
_ = try output(renderer, arguments: [source.path, "--export-image", "--output-file", rendered.path,
                                    "--platform", "macOS", "--rendition", "Default", "--width", "1024",
                                    "--height", "1024", "--scale", "4", "--design-generation", "27"])
guard let logo = NSImage(contentsOf: rendered), logo.isValid else { fatalError("Could not read the Icon Composer render") }
// The Composer render touches the canvas edges. Its very bright outer rim can
// turn into disconnected white pixels when Finder resamples the legacy icon.
// Inset the alpha contour by twelve design points, retaining the original artwork
// and material inside it. Padding gives the flat edges transparent neighbors too.
let original = CIImage(contentsOf: rendered)!
let transparent = CIImage(color: .clear).cropped(to: original.extent.insetBy(dx: -64, dy: -64))
let mask = original.composited(over: transparent)
    .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 48])
let cleaned = original.applyingFilter("CIBlendWithAlphaMask", parameters: [
    kCIInputBackgroundImageKey: transparent,
    kCIInputMaskImageKey: mask,
])
let renderContext = CIContext()
guard let cleanImage = renderContext.createCGImage(cleaned, from: original.extent) else {
    fatalError("Could not smooth the icon contour")
}
let cleanLogo = NSImage(cgImage: cleanImage, size: logo.size)
var entries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Could not create the icon") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        context.interpolationQuality = .high
        // Composer provides the gradient, glass relief, lighting and mask. Standard
        // macOS padding keeps the legacy icon consistent with neighboring Dock apps.
        cleanLogo.draw(in: NSRect(x: 64, y: 64, width: 896, height: 896),
                  from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not export the icon") }
        try png.write(to: destination.appendingPathComponent(filename))
        entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
    }
}
let contents: [String: Any] = ["images": entries, "info": ["version": 1, "author": "Resim"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: destination.appendingPathComponent("Contents.json"))
