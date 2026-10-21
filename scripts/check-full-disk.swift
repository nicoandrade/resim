import Foundation
import CryptoKit
import Darwin

@main
struct FullDiskCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let original = root.appendingPathComponent("original.png")
        let candidate = root.appendingPathComponent("candidate.png")
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let data = Data(repeating: 87, count: 2 * 1_024 * 1_024)
        try data.write(to: original)
        try data.write(to: candidate)
        let before = SHA256.hash(data: try Data(contentsOf: original))
        var recordedError: NSError?
        do {
            _ = try SafeFiles.preparePublication(candidate: candidate, original: original,
                settings: .init(destination: destination), workDirectory: work, cancellation: CancellationToken())
        } catch { recordedError = error as NSError }
        guard let error = recordedError else { fatalError("Full volume unexpectedly accepted complete candidate") }
        let after = SHA256.hash(data: try Data(contentsOf: original))
        let stages = try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasPrefix(".resim-stage-") || $0.contains("optimized") }
        guard before == after, stages.isEmpty else { fatalError("Original/stage integrity regression") }
        var cursor: NSError? = error
        var outOfSpace = false
        var errors: [[String: Any]] = []
        while let current = cursor {
            errors.append(["domain":current.domain,"code":current.code])
            if current.domain == NSPOSIXErrorDomain && current.code == Int(ENOSPC) { outOfSpace = true }
            if current.domain == NSCocoaErrorDomain && current.code == NSFileWriteOutOfSpaceError { outOfSpace = true }
            cursor = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        guard outOfSpace else { fatalError("Failure was not ENOSPC: \(error)") }
        let result: [String: Any] = ["passed":true, "errors":errors,"original_sha256":before.map { String(format:"%02x", $0) }.joined(),"original_intact":true,"stages_remaining":stages.count,"candidate_bytes":data.count]
        let report = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys])
        try report.write(to: root.appendingPathComponent("report.json"))
        print(String(decoding: report, as: UTF8.self))
    }
}
