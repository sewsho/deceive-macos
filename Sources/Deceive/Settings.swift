import Foundation

/// State shared between the menu bar (main thread) and the proxied connections (their own queues).
final class Settings {
    private let lock = NSLock()
    private var _enabled = true
    private var _status = "offline"
    private var _connectToMuc = true

    var enabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue } }
    }

    /// "chat" (online), "offline" or "mobile".
    var status: String {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }

    /// Whether lobby (MUC) presences are passed through.
    var connectToMuc: Bool {
        get { lock.withLock { _connectToMuc } }
        set { lock.withLock { _connectToMuc = newValue } }
    }
}
