import AppKit
import Network

/// Menu bar equivalent of upstream's tray icon. Lives on the main thread.
@MainActor
final class MainController: NSObject {
    let settings = Settings()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var connections: [ProxiedConnection] = []
    private var sentIntroductionText = false
    private var shutdownTimer: Timer?

    override init() {
        super.init()
        loadStatus()
        updateMenu()
    }

    // MARK: Connections

    func serve(_ incoming: NWConnection, chatHost: String, chatPort: Int) {
        // No need to shut down, we received a new connection.
        shutdownTimer?.invalidate()
        shutdownTimer = nil

        let connection = ProxiedConnection(incoming: incoming, chatHost: chatHost, chatPort: chatPort, settings: settings)
        connection.onClosed = { [weak self, weak connection] in
            guard let self else { return }
            Log.write("Disconnected incoming connection.")
            self.connections.removeAll { $0 === connection }
            if self.connections.isEmpty { self.shutdownIfNoReconnect() }
        }
        connection.onChatMessage = { [weak self] content in self?.handleChatMessage(content) }
        connection.onUpstreamUnreachable = { retry in
            let choice = Alert.show(
                "Unable to connect to the chat server. Please check your internet connection. If this issue persists " +
                "and you can connect to chat normally without Deceive, please file a bug report at \(Utils.issuesURL.absoluteString).",
                style: .critical,
                buttons: ["Retry", "Quit"]
            )
            if choice == 0 { retry() } else { exit(0) }
        }
        connections.append(connection)
        connection.start()

        if !sentIntroductionText && !Persistence.hasShownIntroduction() {
            sentIntroductionText = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.sendIntroductionText() }
        }
    }

    private func shutdownIfNoReconnect() {
        shutdownTimer?.invalidate()
        shutdownTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
            Log.write("Received no new connections after 60s, shutting down.")
            exit(0)
        }
    }

    // MARK: Menu

    private func updateMenu() {
        let symbol = settings.enabled ? "theatermasks.fill" : "theatermasks"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Deceive")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = settings.enabled ? "Deceive: appearing \(statusDescription)" : "Deceive: disabled"

        let menu = NSMenu()
        menu.autoenablesItems = false

        let about = NSMenuItem(title: Utils.title, action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(.separator())

        menu.addItem(item("Enabled", checked: settings.enabled) { $0.toggleEnabled() })

        let statusMenu = NSMenu()
        for (title, status) in [("Online", "chat"), ("Offline", "offline"), ("Mobile", "mobile")] {
            statusMenu.addItem(item(title, checked: settings.status == status) { $0.setStatus(status) })
        }
        menu.addItem(submenu("Status Type", statusMenu))

        let startupStatus = Persistence.startupStatus()
        let startupMenu = NSMenu()
        for (title, status) in [("Online", "chat"), ("Offline", "offline"), ("Mobile", "mobile"), ("Remember Last", "last")] {
            startupMenu.addItem(item(title, checked: startupStatus == status) { controller in
                Persistence.setStartupStatus(status)
                controller.updateMenu()
            })
        }
        menu.addItem(submenu("Default Status on Startup", startupMenu))

        menu.addItem(item("Enable lobby chat", checked: settings.connectToMuc) { controller in
            controller.settings.connectToMuc.toggle()
            controller.updateMenu()
        })

        menu.addItem(.separator())
        menu.addItem(item("Restart and launch a different game") { $0.restartWithDifferentGame() })
        menu.addItem(item("Open debug log") { _ in NSWorkspace.shared.open(Persistence.debugLogURL) })
#if DEBUG
        menu.addItem(item("Send test message") { $0.sendMessageFromFakePlayer("Test") })
#endif
        menu.addItem(item("Quit", key: "q") { $0.quit() })

        statusItem.menu = menu
    }

    private var statusDescription: String { settings.status == "chat" ? "online" : settings.status }

    private func item(_ title: String, checked: Bool = false, key: String = "",
                      action: @escaping (MainController) -> Void) -> NSMenuItem {
        let menuItem = ClosureMenuItem(title: title, keyEquivalent: key) { [weak self] in
            if let self { action(self) }
        }
        menuItem.state = checked ? .on : .off
        return menuItem
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.submenu = menu
        return menuItem
    }

    // MARK: Actions

    private func toggleEnabled() {
        settings.enabled.toggle()
        updateStatus(settings.enabled ? settings.status : "chat")
        sendMessageFromFakePlayer(settings.enabled ? "Deceive is now enabled." : "Deceive is now disabled.")
        updateMenu()
    }

    private func setStatus(_ status: String) {
        settings.status = status
        settings.enabled = true
        // Upstream only saves on Quit; Deceive usually exits with the Riot Client instead, so save right away.
        saveStatus()
        updateStatus(status)
        updateMenu()
    }

    private func restartWithDifferentGame() {
        let choice = Alert.show(
            "Restart Deceive to launch a different game? This will also stop related games if they are running.",
            buttons: ["Restart", "Cancel"]
        )
        guard choice == 0 else { return }

        Utils.killProcesses()
        Persistence.setDefaultLaunchGame(.prompt)
        saveStatus()
        relaunch()
    }

    private func quit() {
        let choice = Alert.show(
            "Are you sure you want to stop Deceive? This will also stop related games if they are running.",
            buttons: ["Quit", "Cancel"]
        )
        guard choice == 0 else { return }

        Utils.killProcesses()
        saveStatus()
        exit(0)
    }

    private func relaunch() {
        // Start the new instance only after this one has exited; otherwise it would find us running and
        // offer to stop "the Riot Client".
        let bundleURL = Bundle.main.bundleURL
        let target = bundleURL.pathExtension == "app" ? bundleURL.path : (Bundle.main.executablePath ?? "")
        let launch = bundleURL.pathExtension == "app" ? "/usr/bin/open -n \"$1\"" : "\"$1\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; \(launch)", "sh", target]
        try? process.run()
        exit(0)
    }

    // MARK: Chat commands

    func handleChatMessage(_ content: String) {
        let lowered = content.lowercased()
        if lowered.contains("offline") {
            if !settings.enabled { sendMessageFromFakePlayer("Deceive is now enabled.") }
            setStatus("offline")
        } else if lowered.contains("mobile") {
            if !settings.enabled { sendMessageFromFakePlayer("Deceive is now enabled.") }
            setStatus("mobile")
        } else if lowered.contains("online") {
            if !settings.enabled { sendMessageFromFakePlayer("Deceive is now enabled.") }
            setStatus("chat")
        } else if lowered.contains("enable") {
            if settings.enabled {
                sendMessageFromFakePlayer("Deceive is already enabled.")
            } else {
                toggleEnabled()
            }
        } else if lowered.contains("disable") {
            if !settings.enabled {
                sendMessageFromFakePlayer("Deceive is already disabled.")
            } else {
                toggleEnabled()
            }
        } else if lowered.contains("status") {
            sendMessageFromFakePlayer("You are appearing \(statusDescription).")
        } else if lowered.contains("help") {
            sendMessageFromFakePlayer(
                "You can send the following messages to quickly change Deceive settings: online/offline/mobile/enable/disable/status")
        }
    }

    private func sendIntroductionText() {
        Persistence.setHasShownIntroduction()
        let messages = [
            "Welcome! Deceive is running and you are currently appearing \(statusDescription). Despite what the game " +
                "client may indicate, you are appearing offline to your friends unless you manually disable Deceive.",
            "If you want to invite others while being offline, you may need to disable Deceive for them to accept. " +
                "You can enable Deceive again as soon as they are in your lobby.",
            "To enable or disable Deceive, or to configure other settings, find Deceive in your menu bar.",
            "Have fun!",
        ]
        for (index, message) in messages.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * Double(index)) { [weak self] in
                self?.sendMessageFromFakePlayer(message)
            }
        }
    }

    private func sendMessageFromFakePlayer(_ message: String) {
        connections.forEach { $0.sendMessageFromFakePlayer(message) }
    }

    private func updateStatus(_ newStatus: String) {
        connections.forEach { $0.updateStatus(newStatus) }
        sendMessageFromFakePlayer(newStatus == "chat" ? "You are now appearing online." : "You are now appearing \(newStatus).")
    }

    // MARK: Persistence

    private func loadStatus() {
        let startupStatus = Persistence.startupStatus()
        if ["chat", "offline", "mobile"].contains(startupStatus) {
            settings.status = startupStatus
            return
        }
        // "last" or unrecognized: use the saved session status.
        let saved = Persistence.lastStatus()
        settings.status = saved == "chat" || saved == "mobile" ? saved! : "offline"
    }

    func saveStatus() {
        Persistence.setLastStatus(settings.status)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
