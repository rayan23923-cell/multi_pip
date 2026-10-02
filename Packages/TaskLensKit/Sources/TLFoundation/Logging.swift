import Foundation
#if canImport(OSLog)
import OSLog
#endif

public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug
    case info
    case notice
    case warning
    case error
    case fault

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Destination for log lines.
public protocol LogSink: Sendable {
    func write(level: LogLevel, subsystem: String, category: String, message: String)
}

/// Lightweight logger passed into services.
///
/// Privacy rule: log identifiers, counts and states only. Never log content
/// the user captured (text, URLs, OCR output, clipboard data).
public struct TLLogger: Sendable {
    public let subsystem: String
    public let category: String
    public let minimumLevel: LogLevel
    private let sink: any LogSink

    public init(
        subsystem: String = TLLogger.defaultSubsystem,
        category: String,
        minimumLevel: LogLevel = .debug,
        sink: any LogSink = TLLogger.defaultSink
    ) {
        self.subsystem = subsystem
        self.category = category
        self.minimumLevel = minimumLevel
        self.sink = sink
    }

    public static let defaultSubsystem = "app.tasklens"

    public static var defaultSink: any LogSink {
        #if canImport(OSLog)
        OSLogSink()
        #else
        PrintLogSink()
        #endif
    }

    /// A logger that drops everything. Useful for previews.
    public static func disabled(category: String = "disabled") -> TLLogger {
        TLLogger(category: category, minimumLevel: .fault, sink: NullLogSink())
    }

    public func scoped(_ category: String) -> TLLogger {
        TLLogger(subsystem: subsystem, category: category, minimumLevel: minimumLevel, sink: sink)
    }

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        guard level >= minimumLevel else { return }
        sink.write(level: level, subsystem: subsystem, category: category, message: message())
    }

    public func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    public func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    public func notice(_ message: @autoclosure () -> String) { log(.notice, message()) }
    public func warning(_ message: @autoclosure () -> String) { log(.warning, message()) }
    public func error(_ message: @autoclosure () -> String) { log(.error, message()) }
    public func fault(_ message: @autoclosure () -> String) { log(.fault, message()) }
}

#if canImport(OSLog)
public struct OSLogSink: LogSink {
    public init() {}

    public func write(level: LogLevel, subsystem: String, category: String, message: String) {
        let logger = Logger(subsystem: subsystem, category: category)
        // Messages are already scrubbed of user content by convention, so they are public.
        logger.log(level: level.osLogType, "\(message, privacy: .public)")
    }
}

extension LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice, .warning: .default
        case .error: .error
        case .fault: .fault
        }
    }
}
#endif

public struct PrintLogSink: LogSink {
    public init() {}

    public func write(level: LogLevel, subsystem: String, category: String, message: String) {
        print("[\(subsystem)/\(category)] [\(level)] \(message)")
    }
}

public struct NullLogSink: LogSink {
    public init() {}
    public func write(level: LogLevel, subsystem: String, category: String, message: String) {}
}

/// Captures log lines in memory, for tests.
public final class RecordingLogSink: LogSink, @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        public let level: LogLevel
        public let category: String
        public let message: String
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    public init() {}

    public var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func write(level: LogLevel, subsystem: String, category: String, message: String) {
        lock.lock()
        storage.append(Entry(level: level, category: category, message: message))
        lock.unlock()
    }
}
