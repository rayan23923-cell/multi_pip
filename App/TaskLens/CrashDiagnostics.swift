import Foundation
import MetricKit
import TLFoundation

/// Receives the crash, hang and energy reports iOS collects for this app
/// (MetricKit) and writes a short summary to the device log. Nothing is sent
/// anywhere; the reports reach the developer only through Xcode Organizer when
/// the user shares analytics with app developers in iOS Settings.
final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashDiagnostics()
    private let logger = TLLogger(category: "diagnostics")

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            let cpu = payload.cpuExceptionDiagnostics?.count ?? 0
            let disk = payload.diskWriteExceptionDiagnostics?.count ?? 0
            logger.warning("Diagnostics: \(crashes) crash(es), \(hangs) hang(s), \(cpu) CPU and \(disk) disk-write exception(s)")
            for crash in payload.crashDiagnostics ?? [] {
                let type = crash.exceptionType.map { "\($0)" } ?? "?"
                let signal = crash.signal.map { "\($0)" } ?? "?"
                logger.error("Crash: exception \(type) signal \(signal) app \(crash.applicationVersion)")
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            if let launch = payload.applicationLaunchMetrics {
                logger.info("Launch metrics: \(launch.histogrammedTimeToFirstDraw.totalBucketCount) samples")
            }
            if let memory = payload.memoryMetrics {
                logger.info("Peak memory: \(memory.peakMemoryUsage)")
            }
        }
    }
}
