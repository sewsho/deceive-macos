import AppKit
import Darwin
import Foundation

enum Utils {
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "v" + (short ?? "1.0.0")
    }

    static var title: String { "Deceive for macOS \(version)" }

    static let repositoryURL = URL(string: "https://github.com/sewsho/deceive-macos")!
    static let issuesURL = repositoryURL.appendingPathComponent("issues")

    // MARK: Updates

    /// Checks GitHub for a newer release and, unless the user already dismissed that version, offers to open it.
    @MainActor
    static func checkForUpdates() async {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/sewsho/deceive-macos/releases/latest")!)
        request.setValue("Deceive-macOS/\(version)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let release = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let latestVersion = release["tag_name"] as? String,
              let pageURL = (release["html_url"] as? String).flatMap(URL.init(string:)),
              isVersion(latestVersion, newerThan: version),
              Persistence.promptedUpdateVersion() != latestVersion else {
            return
        }

        Persistence.setPromptedUpdateVersion(latestVersion)
        let choice = Alert.show(
            "There is a new version of Deceive for macOS available: \(latestVersion). You are currently using \(version). " +
            "Updates usually fix critical bugs or adapt to changes by Riot, so it is recommended that you install the " +
            "latest version.\n\nWe won't show this message again for this version if you choose Later.",
            buttons: ["Open Download Page", "Later"]
        )
        if choice == 0 { NSWorkspace.shared.open(pageURL) }
    }

    /// Compares versions like "v1.2.3" and "v1.2.3-beta.1". A pre-release suffix sorts before its release, as in SemVer.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> (release: [Int], preRelease: [Substring]?) {
            let trimmed = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let halves = trimmed.split(separator: "-", maxSplits: 1)
            let release = (halves.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            return (release, halves.count > 1 ? halves[1].split(separator: ".") : nil)
        }
        let (a, b) = (parts(candidate), parts(current))
        for index in 0..<max(a.release.count, b.release.count) {
            let (x, y) = (index < a.release.count ? a.release[index] : 0, index < b.release.count ? b.release[index] : 0)
            if x != y { return x > y }
        }

        switch (a.preRelease, b.preRelease) {
        case (nil, nil), (.some, nil): return false
        case (nil, .some): return true
        case let (x?, y?):
            for (p, q) in zip(x, y) where p != q {
                if let p = Int(p), let q = Int(q) { return p > q }
                return p > q
            }
            return x.count > y.count
        }
    }

    // MARK: Riot Client discovery

    private static let installsURL = URL(fileURLWithPath: "/Users/Shared/Riot Games/RiotClientInstalls.json")

    /// Checks for any installed Riot Client configuration and returns the path of the client, if any.
    static func riotClientPath() -> String? {
        // The Riot Client occasionally corrupts this file; treat that like a missing install.
        guard let data = try? Data(contentsOf: installsURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return ["rc_default", "rc_live", "rc_beta"]
            .compactMap { json[$0] as? String }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Processes

    /// Riot processes that need to be restarted for Deceive to take effect.
    private static let riotProcessNames: Set<String> = ["RiotClientServices", "LeagueClient", "League of Legends"]

    private static func processes(named names: Set<String>) -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        let ownPid = getpid()
        return pids.prefix(max(0, count)).filter { pid in
            guard pid > 0, pid != ownPid else { return false }
            var name = [CChar](repeating: 0, count: 4 * Int(MAXCOMLEN) + 1)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return false }
            return names.contains(String(cString: name))
        }
    }

    /// Other Deceive instances, plus the Riot Client and its games.
    private static func relatedProcesses() -> [pid_t] {
        let ownName = ProcessInfo.processInfo.processName
        return processes(named: riotProcessNames.union([ownName]))
    }

    static func riotClientPid() -> pid_t? { processes(named: ["RiotClientServices"]).first }

    static func isClientRunning() -> Bool { !relatedProcesses().isEmpty }

    /// Stops the Riot Client, its games and other Deceive instances, waiting up to five seconds for them to exit.
    static func killProcesses() {
        let pids = relatedProcesses()
        pids.forEach { kill($0, SIGTERM) }

        let deadline = Date().addingTimeInterval(5)
        var remaining = pids
        while !remaining.isEmpty, Date() < deadline {
            usleep(100_000)
            remaining = remaining.filter { kill($0, 0) == 0 }
        }
        remaining.forEach { kill($0, SIGKILL) }
    }

    /// Spawns a child process that macOS treats as responsible for itself, the way Terminal launches commands.
    /// Otherwise privacy prompts the Riot Client triggers (such as writing to Discord's data) would name Deceive.
    /// Unlike launching through Launch Services, the Riot Client stays our child, exactly as before.
    static func spawnDisclaimed(path: String, arguments: [String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        var noSignals = sigset_t(), allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        // Private, but in libSystem since macOS 10.14; without it the child just stays attributed to Deceive.
        typealias SetDisclaimFunction = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
            _ = unsafeBitCast(symbol, to: SetDisclaimFunction.self)(&attributes, 1)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&fileActions, fd, "/dev/null", fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &fileActions, &attributes, argv, environ)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
        return pid
    }

    // MARK: DNS

    private static func localhostDomainResolves() -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ConfigProxy.localhostDomain, nil, &hints, &result) == 0 else { return false }
        defer { freeaddrinfo(result) }

        var cursor = result
        while let info = cursor {
            if let address = info.pointee.ai_addr, info.pointee.ai_family == AF_INET {
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if ipv4.s_addr == inet_addr("127.0.0.1") { return true }
            }
            cursor = info.pointee.ai_next
        }
        return false
    }

    /// Exits unless deceive-localhost.molenzwiebel.xyz resolves to 127.0.0.1, offering to open the FAQ.
    @MainActor
    static func ensureLocalhostResolution() {
        if localhostDomainResolves() { return }

        let result = Alert.show(
            "Your machine is failing to resolve some required domains. You will need to switch DNS servers or add " +
            "\"127.0.0.1 \(ConfigProxy.localhostDomain)\" to /etc/hosts. Deceive will not work until this issue is " +
            "resolved. Would you like to open the FAQ now?",
            style: .warning,
            buttons: ["Open FAQ", "Quit"]
        )
        if result == 0 {
            NSWorkspace.shared.open(URL(string: repositoryURL.absoluteString + "#faq")!)
        }
        exit(0)
    }
}

enum Alert {
    /// Shows a modal alert and returns the index of the button that was pressed.
    @MainActor
    @discardableResult
    static func show(_ message: String, style: NSAlert.Style = .informational, buttons: [String] = ["OK"]) -> Int {
        let alert = NSAlert()
        alert.messageText = Utils.title
        alert.informativeText = message
        alert.alertStyle = style
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}
