#!/usr/bin/swift
import Foundation
import ImageIO
import UniformTypeIdentifiers
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ResimTests/Fixtures")
let source = CGImageSourceCreateWithURL(root.appendingPathComponent("landscape.png") as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
func jpeg(_ name: String, properties: [CFString: Any]) {
    let dest = CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
}
jpeg("landscape.jpg", properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
jpeg("already-compressed.jpg", properties: [kCGImageDestinationLossyCompressionQuality: 0.45])
jpeg("orientation-gps.jpg", properties: [kCGImageDestinationLossyCompressionQuality: 0.98, kCGImagePropertyOrientation: 6,
    kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 34.6, kCGImagePropertyGPSLatitudeRef: "S", kCGImagePropertyGPSLongitude: 58.4, kCGImagePropertyGPSLongitudeRef: "W"],
    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Resim Fixture", kCGImagePropertyTIFFArtist: "Synthetic data"]])
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
if let icc = colorSpace.copyICCData() { try (icc as Data).write(to: root.appendingPathComponent("sRGB.icc")) }

let photoURL = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("vendor/src/mozjpeg-4.1.5/testimages/testorig.ppm")
if let photoSource = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
   let photo = CGImageSourceCreateImageAtIndex(photoSource, 0, nil),
   let photoDestination = CGImageDestinationCreateWithURL(root.appendingPathComponent("photo-quality100.jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
    CGImageDestinationAddImage(photoDestination, photo, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
    precondition(CGImageDestinationFinalize(photoDestination))
}
