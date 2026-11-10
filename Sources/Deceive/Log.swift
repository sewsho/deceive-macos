import Foundation

/// Mirrors upstream's Trace output: everything goes to stdout and, once configured, to debug.log.
enum Log {
    private static let queue = DispatchQueue(label: "deceive.log")
    private static var file: FileHandle?

    static func setUp(fileURL: URL) {
        queue.sync {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            file = try? FileHandle(forWritingTo: fileURL)
        }
    }

    static func write(_ message: @autoclosure () -> String) {
        let line = message() + "\n"
        queue.async {
            FileHandle.standardOutput.write(Data(line.utf8))
            file?.write(Data(line.utf8))
        }
    }
}
