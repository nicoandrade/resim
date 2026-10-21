import Foundation
import AppKit
import Darwin

/// Opt-in local instrumentation for reproducible Release measurements. No files are written
/// during normal use, and no image names, metadata or pixels enter this report.
@MainActor
enum LaunchDiagnostics {
    private static var appStarted = ContinuousClock.now
    private static var recorded = false
    static func begin() { appStarted = .now }
    static func configureAppearance() {
        // Test-only process override; never writes or changes the system appearance.
        switch ProcessInfo.processInfo.environment["RESIM_QA_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }
    static func viewReady() {
        guard !recorded, let path = ProcessInfo.processInfo.environment["RESIM_LAUNCH_REPORT"] else { return }
        recorded = true
        let elapsed = appStarted.duration(to: .now).components
        var process = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &process, size)
        let birth = Double(process.pbi_start_tvsec) + Double(process.pbi_start_tvusec) / 1_000_000
        let report: [String: Double] = [
            "app_init_to_view_ms": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
            "process_birth_to_view_ms": result == size ? (Date().timeIntervalSince1970 - birth) * 1000 : -1,
            "pid": Double(getpid())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = URL(fileURLWithPath: path)
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }
}
