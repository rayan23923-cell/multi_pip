import Foundation

/// Abstracts "now" so services are deterministic under test.
public protocol DateProviding: Sendable {
    func now() -> Date
}

public struct SystemDateProvider: DateProviding {
    public init() {}
    public func now() -> Date { Date() }
}

/// A controllable clock for tests and previews.
public final class ManualDateProvider: DateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        current = start
    }

    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }

    public func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }
}
