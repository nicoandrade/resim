#!/usr/bin/env python3
"""Temporary native encoder diagnosis; no signing credentials or app publication."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
work = root / '.build/heic-diagnosis'
work.mkdir(parents=True, exist_ok=True)
source = (root / 'Resim/Optimizers/HEICProcessor.swift').read_text()
source = '\n'.join(line.replace('return nil', f'return diagnosticNil("HEIC source line {number}")')
                   for number, line in enumerate(source.splitlines(), 1))
(work / 'HEICProcessor.swift').write_text(source)
tests = (root / 'ResimTests/HEICIntegrationTests.swift').read_text()
fixture = tests[tests.index('    private func fixture('):tests.index('\n    private func decoded(')]
fixture = fixture.replace('private func fixture(', 'func fixture(')
fixture = fixture.replace('textured: Bool = false)', 'textured: Bool = false, flat: Int? = nil)')
fixture = fixture.replace('let value = UInt8(100 +', 'let value = UInt8(flat ?? (100 +')
fixture = fixture.replace('/ 8 + texture)', '/ 8 + texture))')
start = fixture.index('        let smoke =')
end = fixture.index('        return result', start)
fixture = fixture[:start] + fixture[end:]
stubs = '''import Foundation
import CoreGraphics
import ImageIO
enum ImageFormat { case heic }
struct ImageInfo { let format: ImageFormat; let width: Int; let height: Int; let hasAlpha: Bool; let estimatedMemory: UInt64 }
enum OptimizationMode: Equatable { case automatic, lossless }
struct OptimizationSettings { var mode: OptimizationMode = .automatic; var stripPersonalMetadata = false }
struct CancellationToken { func check() throws {} }
enum ProcessingError: Error { case resourceLimit(String), unsupported(String), unavailable(String), invalid(String) }
func diagnosticNil<T>(_ reason: String) -> T? { print(reason); return nil }
@_silgen_name("WebPPlaneDistortion")
func plane(_ a: UnsafePointer<UInt8>?, _ sa: Int, _ b: UnsafePointer<UInt8>?, _ sb: Int,
           _ w: Int32, _ h: Int32, _ step: Int, _ type: Int32, _ distortion: UnsafeMutablePointer<Float>, _ score: UnsafeMutablePointer<Float>) -> Int32
func rc_rgba_ssim_rgb(_ a: UnsafePointer<UInt8>?, _ b: UnsafePointer<UInt8>?, _ w: Int32, _ h: Int32) -> Int32 {
    var scores = [Float](), accepted = true
    for channel in 0..<3 {
        var score: Float = 0, distortion: Float = 0
        let ok = plane(a?.advanced(by: channel), Int(w) * 4, b?.advanced(by: channel), Int(w) * 4,
                       w, h, 4, 1, &distortion, &score)
        scores.append(score)
        accepted = accepted && ok != 0 && score.isFinite && score >= 30
    }
    print("RGB SSIM dB: \\(scores)")
    return accepted ? 1 : 0
}
func XCTUnwrap<T>(_ value: T?) throws -> T { guard let value else { fatalError("unwrap") }; return value }
func XCTAssertTrue(_ value: Bool) { precondition(value) }
'''
main = '''
for p3 in [false, true] {
  for flat: Int? in [nil, 0, 64, 128, 192, 255] {
    var data = try fixture(p3: p3, flat: flat)
    if flat != nil {
        var size = UInt32(16_384 + 8).bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(Data("free".utf8)); data.append(Data(repeating: 0, count: 16_384))
    }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let output = try HEICProcessor().optimize(data, workDirectory: work, settings: .init(), cancellation: .init())
    print("p3=\\(p3), flat=\\(String(describing: flat)), input=\\(data.count), output=\\(try output.map { try Data(contentsOf: $0).count } ?? 0)")
  }
}
'''
(work / 'main.swift').write_text(stubs + fixture + main)
prefix = subprocess.check_output(['brew', '--prefix', 'webp'], text=True).strip()
subprocess.run(['xcrun', 'swiftc', str(work / 'main.swift'), str(work / 'HEICProcessor.swift'),
                '-L', prefix + '/lib', '-lwebp', '-Xlinker', '-rpath', '-Xlinker', prefix + '/lib',
                '-o', str(work / 'diagnose')], check=True)
subprocess.run([str(work / 'diagnose')], check=True)
