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
func rc_rgba_ssim_rgb(_ a: UnsafePointer<UInt8>?, _ b: UnsafePointer<UInt8>?, _ w: Int32, _ h: Int32) -> Int32 {
    print("Reached RGB quality gate (bypassed for stage diagnosis)"); return 1
}
func XCTUnwrap<T>(_ value: T?) throws -> T { guard let value else { fatalError("unwrap") }; return value }
func XCTAssertTrue(_ value: Bool) { precondition(value) }
'''
main = '''
for p3 in [false, true] {
    let data = try fixture(p3: p3)
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let output = try HEICProcessor().optimize(data, workDirectory: work, settings: .init(), cancellation: .init())
    print("p3=\\(p3), input=\\(data.count), output=\\(try output.map { try Data(contentsOf: $0).count } ?? 0)")
}
'''
(work / 'main.swift').write_text(stubs + fixture + main)
subprocess.run(['xcrun', 'swiftc', str(work / 'main.swift'), str(work / 'HEICProcessor.swift'),
                '-o', str(work / 'diagnose')], check=True)
subprocess.run([str(work / 'diagnose')], check=True)
