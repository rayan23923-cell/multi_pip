import Foundation

enum TemporaryDirectory {
    static func make() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskLensTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
