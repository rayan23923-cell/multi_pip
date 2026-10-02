import Foundation
import Testing
@testable import TLFoundation

@Suite("Logging")
struct LoggingTests {
    @Test func respectsMinimumLevel() {
        let sink = RecordingLogSink()
        let logger = TLLogger(category: "test", minimumLevel: .warning, sink: sink)
        logger.debug("hidden")
        logger.info("hidden")
        logger.warning("shown")
        logger.error("shown too")
        #expect(sink.entries.map(\.level) == [.warning, .error])
    }

    @Test func scopedLoggerKeepsSinkAndChangesCategory() {
        let sink = RecordingLogSink()
        let logger = TLLogger(category: "root", sink: sink).scoped("child")
        logger.info("hello")
        #expect(sink.entries == [.init(level: .info, category: "child", message: "hello")])
    }

    @Test func disabledLoggerDoesNotEvaluateMessages() {
        var evaluated = false
        func message() -> String {
            evaluated = true
            return "x"
        }
        TLLogger.disabled().info(message())
        #expect(evaluated == false)
    }
}
