import Foundation

enum Persistence {
    static let dataDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Deceive", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let updateVersionURL = dataDir.appendingPathComponent("updateVersionPrompted")
    private static let defaultLaunchGameURL = dataDir.appendingPathComponent("launchGame")
    private static let cachedCertURL = dataDir.appendingPathComponent("localhostCert.pfx")
    private static let startupStatusURL = dataDir.appendingPathComponent("startupStatus")
    private static let introductionShownURL = dataDir.appendingPathComponent("introductionShown")
    static let statusURL = dataDir.appendingPathComponent("status")
    static let debugLogURL = dataDir.appendingPathComponent("debug.log")

    private static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private static func write(_ url: URL, _ value: String) {
        try? value.write(to: url, atomically: true, encoding: .utf8)
    }

    // Latest release version the user was already told about.
    static func promptedUpdateVersion() -> String? { read(updateVersionURL) }
    static func setPromptedUpdateVersion(_ version: String) { write(updateVersionURL, version) }

    // Configured launch option.
    static func defaultLaunchGame() -> LaunchGame {
        guard let contents = read(defaultLaunchGameURL), let game = LaunchGame(argument: contents) else {
            return .prompt
        }
        return game
    }

    static func setDefaultLaunchGame(_ game: LaunchGame) { write(defaultLaunchGameURL, game.rawValue) }

    // Cached deceive-localhost.molenzwiebel.xyz certificate.
    static func cachedCertificate() -> Data? { try? Data(contentsOf: cachedCertURL) }
    static func setCachedCertificate(_ data: Data) { try? data.write(to: cachedCertURL, options: .atomic) }

    // Startup status: "chat", "offline", "mobile", or "last" (remember last session).
    static func startupStatus() -> String { read(startupStatusURL) ?? "last" }
    static func setStartupStatus(_ status: String) { write(startupStatusURL, status) }

    // Status of the previous session, used when the startup status is "last".
    static func lastStatus() -> String? { read(statusURL) }
    static func setLastStatus(_ status: String) { write(statusURL, status) }

    // Whether the introduction/welcome text has already been shown to the user.
    static func hasShownIntroduction() -> Bool { FileManager.default.fileExists(atPath: introductionShownURL.path) }
    static func setHasShownIntroduction() { write(introductionShownURL, "") }
}
