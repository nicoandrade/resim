import XCTest
import AppKit
@testable import Resim

final class SVGIntegrationTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        let url = root.appendingPathComponent("Fixtures/\(name)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), name)
        return url
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resim-svg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func optimize(_ name: String, mode: OptimizationMode = .lossless) throws -> (Data, Data) {
        let source = try fixture(name), original = try Data(contentsOf: source)
        let result = try XCTUnwrap(NativeImageProcessor().optimize(source: source, workDirectory: directory(),
            settings: .init(mode: mode, stripPersonalMetadata: false), cancellation: CancellationToken()),
            "Pretty-printed SVG must really shrink: \(name)")
        let candidate = try Data(contentsOf: result)
        XCTAssertLessThan(candidate.count, original.count)
        XCTAssertEqual(result.pathExtension, "svg")
        XCTAssertEqual(try Data(contentsOf: source), original, "Never modify the original SVG")
        XCTAssertTrue(SVGProcessor().semanticsPreserved(original: original, candidate: candidate))
        let before = try SVGProcessor().inspect(original), after = try SVGProcessor().inspect(candidate)
        XCTAssertEqual(before.format, .svg); XCTAssertEqual(after.format, .svg)
        XCTAssertEqual(before.width, after.width); XCTAssertEqual(before.height, after.height)
        print("SVG \(mode.rawValue) \(name): \(original.count) -> \(candidate.count)")
        return (original, candidate)
    }

    /// AppKit's native SVG decoder is independent of SVGO and the XML guard.
    @MainActor
    private func pixels(_ data: Data) throws -> Data {
        let image = try XCTUnwrap(NSImage(data: data))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 128 * 4, bitsPerPixel: 32))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 128, height: 128).fill(using: .copy)
        image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128), from: .zero,
                   operation: .copy, fraction: 1)
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    func testStaticSVGActuallyReducesInBothModesWithoutChangingSource() throws {
        for mode in OptimizationMode.allCases {
            for name in ["svg-icon.svg", "svg-references.svg"] {
                _ = try optimize(name, mode: mode)
            }
        }
    }

    @MainActor
    func testNativeRenderingMatchesAfterOptimizationIncludingLocalReferences() throws {
        for name in ["svg-icon.svg", "svg-references.svg"] {
            let (original, candidate) = try optimize(name)
            let before = try pixels(original), after = try pixels(candidate)
            XCTAssertTrue(before.contains { $0 != 0 }, "Fixture must render actual visible pixels")
            XCTAssertEqual(before, after, "AppKit render must match exactly: \(name)")
        }
    }

    func testKeepsMetadataLicenseTextCSSIDsReferencesAndHighPrecisionNumbers() throws {
        let (_, candidate) = try optimize("svg-references.svg")
        let xml = try XCTUnwrap(String(data: candidate, encoding: .utf8))
        for literal in ["License: CC0-1.0. Own fixture; this license comment must survive.",
            "Sol, montaña y café — Ñ 试 ☀", "Author: Pruebas Resim; rights: CC0-1.0; user text:  a  b  ",
            ".mountain { fill: currentColor; } .sun { fill: #fff2ba; }", "M 6.123456789 106 L 44 58 L 74 94 L 92 74 L 122 106 Z",
            "sunsetGradient", "roundClip", "sunMask", "mountainShape", "url(#sunsetGradient)",
            "url(#roundClip)", "url(#sunMask)", "#mountainShape", "Ñ 试  café ", " a  b "] {
            XCTAssertTrue(xml.contains(literal), "Content must survive exactly: \(literal)")
        }
    }

    func testSemanticGuardRejectsChangedPathViewBoxIDTextMetadataAndLicense() throws {
        let original = try Data(contentsOf: fixture("svg-references.svg"))
        let xml = try XCTUnwrap(String(data: original, encoding: .utf8)), processor = SVGProcessor()
        XCTAssertTrue(processor.semanticsPreserved(original: original, candidate: original))
        for (before, after) in [
            ("6.123456789", "6.123456788"), ("0 0 128 128", "0 0 127 128"),
            ("sunsetGradient", "renamedGradient"), ("café", "cafe"),
            ("user text:  a  b  ", "user text: a b"), ("CC0-1.0", "CC-BY-4.0"),
            ("Ñ 试  café ", "Ñ 试 café "), ("<tspan> a  b </tspan>", "<tspan>a b</tspan>"),
            (".mountain { fill: currentColor; }", ".mountain { fill: red; }")
        ] {
            let changed = Data(xml.replacingOccurrences(of: before, with: after).utf8)
            XCTAssertNotEqual(original, changed, "Mutation must actually change fixture: \(before)")
            XCTAssertFalse(processor.semanticsPreserved(original: original, candidate: changed), before)
        }
    }

    func testContentSniffingIgnoresExtensionAndOutputsSVG() throws {
        let original = try Data(contentsOf: fixture("svg-icon.svg")), work = try directory()
        let source = work.appendingPathComponent("Paisaje Ñ 试.PNG")
        try original.write(to: source)
        let processor = NativeImageProcessor()
        XCTAssertEqual(try processor.inspect(source).format, .svg)
        let output = try XCTUnwrap(processor.optimize(source: source, workDirectory: work,
            settings: .init(), cancellation: CancellationToken()))
        XCTAssertEqual(output.pathExtension, "svg")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPrefixedSVGNamespaceRootAndAttributesRemainIntact() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:svg xmlns:s="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
            <s:rect id="square" x="0" y="0" width="16" height="16" fill="#f08060" />
        </s:svg>
        """
        let original = Data(xml.utf8), processor = SVGProcessor()
        XCTAssertEqual(try processor.inspect(original).width, 16)
        let work = try directory(), source = work.appendingPathComponent("namespaced.svg")
        try original.write(to: source)
        XCTAssertEqual(try NativeImageProcessor().inspect(source).format, .svg)
        let output = try XCTUnwrap(NativeImageProcessor().optimize(source: source, workDirectory: work,
            settings: .init(), cancellation: CancellationToken()))
        let candidate = try Data(contentsOf: output)
        XCTAssertTrue(processor.semanticsPreserved(original: original, candidate: candidate))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testAlreadyMinifiedSVGDoesNotProduceRedundantOutput() throws {
        let (_, optimized) = try optimize("svg-icon.svg")
        let work = try directory(), source = work.appendingPathComponent("already-minified.svg")
        try optimized.write(to: source)
        XCTAssertNil(try NativeImageProcessor().optimize(source: source, workDirectory: work,
            settings: .init(), cancellation: CancellationToken()))
        XCTAssertEqual(try Data(contentsOf: source), optimized)
    }

    func testPersonalMetadataStrippingIsExplicitlyUnsupported() throws {
        let source = try fixture("svg-references.svg"), original = try Data(contentsOf: source)
        XCTAssertThrowsError(try NativeImageProcessor().optimize(source: source, workDirectory: directory(),
            settings: .init(stripPersonalMetadata: true), cancellation: CancellationToken()))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testRejectsActiveContentExternalResourcesDTDAndEscapedCSS() throws {
        let wrappers = [
            "<script>alert(1)</script>", "<foreignObject><div>HTML</div></foreignObject>",
            "<rect width=\"8\" height=\"8\" onclick=\"alert(1)\"/>",
            "<image href=\"https://example.invalid/image.png\"/>",
            "<use href=\"file:///etc/passwd#secret\"/>",
            "<image href=\"data:image/png;base64,AAAA\"/>",
            "<style>@import url(https://example.invalid/style.css);</style>",
            "<rect fill=\"url(https://example.invalid/paint.svg#x)\"/>",
            "<style>rect { fill: u\\72l(https://example.invalid/x); }</style>",
            "<style>rect { fill: url(\\68ttps://example.invalid/x); }</style>",
            "<style>svg { background: image-set('relative.png' 1x); }</style>",
            "<style>svg { background: -webkit-image-set('relative.png' 1x); }</style>",
            "<rect fill=\"image('relative.png')\"/>",
            "<rect fill=\"src('relative.png')\"/>",
            "<rect fill=\"u\\72l(https://example.invalid/x)\"/>",
            "<a href=\"https://example.invalid/\"><rect width=\"1\" height=\"1\"/></a>",
            "<g xml:base=\"https://example.invalid/\"><use href=\"#a\"/></g>"
        ]
        let processor = SVGProcessor()
        for body in wrappers {
            let xml = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\">\(body)</svg>"
            XCTAssertThrowsError(try processor.inspect(Data(xml.utf8)), body)
        }
        for xml in [
            "<!DOCTYPE svg [<!ENTITY ext SYSTEM 'file:///etc/passwd'>]><svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><text>&ext;</text></svg>",
            "<!DOCTYPE svg SYSTEM 'https://example.invalid/svg.dtd'><svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'/>",
            "<!DOCTYPE svg [<!ENTITY a 'expanded'>]><svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><text>&a;</text></svg>"
        ] {
            XCTAssertThrowsError(try processor.inspect(Data(xml.utf8)), "DTD and all entity declarations must be rejected")
        }
    }

    func testRejectsCorruptionWrongNamespaceOversizeNodeAndDepthLimits() throws {
        let processor = SVGProcessor()
        for xml in ["", "<svg", "<svg width='16' height='16'><g></svg>",
            "<html xmlns='http://www.w3.org/1999/xhtml'/>",
            "<svg xmlns='https://example.invalid/not-svg' width='16' height='16'/>",
            "<other:svg xmlns:other='https://example.invalid/not-svg' width='16' height='16'/>"] {
            XCTAssertThrowsError(try processor.inspect(Data(xml.utf8)), xml)
        }
        var invalidUTF8 = Data("<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><text>".utf8)
        invalidUTF8.append(0xFF); invalidUTF8.append(contentsOf: Data("</text></svg>".utf8))
        XCTAssertThrowsError(try processor.inspect(invalidUTF8))
        let oversized = "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><!--"
            + String(repeating: "x", count: 4 * 1_024 * 1_024) + "--></svg>"
        XCTAssertThrowsError(try processor.inspect(Data(oversized.utf8)))
        let deep = "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'>"
            + String(repeating: "<g>", count: 140) + String(repeating: "</g>", count: 140) + "</svg>"
        XCTAssertThrowsError(try processor.inspect(Data(deep.utf8)))
        let nodes = "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'>"
            + String(repeating: "<g/>", count: 50_001) + "</svg>"
        XCTAssertThrowsError(try processor.inspect(Data(nodes.utf8)))
    }

    func testAlreadyCancelledSVGDoesNotSpawnOrWriteWorkFiles() throws {
        let source = try fixture("svg-icon.svg"), original = try Data(contentsOf: source)
        let work = try directory(), token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try NativeImageProcessor().optimize(source: source, workDirectory: work,
            settings: .init(), cancellation: token)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
