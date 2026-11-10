import AppKit
import Foundation

struct LaunchArguments {
    var game: LaunchGame = .auto
    var gamePatchline = "live"
    var riotClientParams: String?
    var gameParams: String?

    /// Usage: Deceive [lol|tft|riotclient|prompt|auto] [--game-patchline X] [--riot-client-params "..."] [--game-params "..."]
    init(_ arguments: [String]) {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--game-patchline": gamePatchline = iterator.next() ?? gamePatchline
            case "--riot-client-params": riotClientParams = iterator.next()
            case "--game-params": gameParams = iterator.next()
            default:
                // Ignore anything else, such as flags macOS or Xcode add.
                if let game = LaunchGame(argument: argument) { self.game = game }
            }
        }
    }
}

@MainActor
enum StartupHandler {
    // Kept alive for the lifetime of the app.
    private static var configProxy: ConfigProxy?
    private static var chatProxy: ChatProxy?
    private static var mainController: MainController?
    private static var riotClientWatcher: DispatchSourceProcess?

    static func start(_ arguments: LaunchArguments) async {
        Log.write("\(Utils.title) starting with arguments:\n" +
                  "LaunchGame: \(arguments.game.rawValue)\n" +
                  "GamePatchline: \(arguments.gamePatchline)\n" +
                  "RiotClientParams: \(arguments.riotClientParams ?? "")\n" +
                  "GameParams: \(arguments.gameParams ?? "")")
        do {
            try await startDeceive(arguments)
        } catch {
            Log.write("\(error)")
            Alert.show("Deceive encountered an error and couldn't properly initialize itself.\n\n\(error)", style: .critical)
            exit(1)
        }
    }

    private static func startDeceive(_ arguments: LaunchArguments) async throws {
        // Refuse to do anything if the client is already running, unless multiple clients are explicitly allowed.
        if Utils.isClientRunning() && !(arguments.riotClientParams?.contains("allow-multiple-clients") ?? false) {
            let choice = Alert.show(
                "The Riot Client is currently running. In order to mask your online status, the Riot Client needs to be " +
                "started by Deceive. Do you want Deceive to stop the Riot Client and games launched by it, so that it can " +
                "restart with the proper configuration?",
                buttons: ["Restart Riot Client", "Cancel"]
            )
            guard choice == 0 else { exit(0) }
            Utils.killProcesses()
            try await Task.sleep(nanoseconds: 2_000_000_000) // The Riot Client takes a while to die.
        }

        Log.setUp(fileURL: Persistence.debugLogURL)
        Log.write(Utils.title)

        // If deceive-localhost.molenzwiebel.xyz does not resolve to 127.0.0.1, nothing will work.
        Utils.ensureLocalhostResolution()

        // Check for updates in the background.
        Task { await Utils.checkForUpdates() }

        guard let riotClientPath = Utils.riotClientPath() else {
            Alert.show(
                "Deceive was unable to find the path to the Riot Client. Usually this can be resolved by launching any " +
                "Riot Games game once, then launching Deceive again.",
                style: .critical
            )
            exit(0)
        }

        var game = arguments.game
        if game == .auto { game = Persistence.defaultLaunchGame() }
        if game == .prompt {
            guard let chosen = GamePrompt.show() else { exit(0) }
            game = chosen
        }

        guard let identity = await ProxyCertificate.obtain() else {
            Alert.show(
                "Deceive was unable to obtain a necessary security certificate for intercepting and modifying the chat " +
                "connection. This normally happens when there's a problem with the server that provides the certificate, " +
                "but it can also be caused by network issues on your end.",
                style: .critical
            )
            exit(0)
        }

        // Open the chat proxy first, so its port can be patched into the client config.
        let chatProxy = try ChatProxy(identity: identity)
        let chatPort = try await chatProxy.start()
        Log.write("Chat proxy listening on port \(chatPort)")

        let configProxy = try ConfigProxy(chatPort: chatPort)
        let configPort = try await configProxy.start()
        Log.write("Config proxy listening on port \(configPort)")

        let mainController = MainController()
        chatProxy.onConnection = { connection, host, port in
            mainController.serve(connection, chatHost: host, chatPort: port)
        }
        configProxy.onPatchedChatServer = { host, port in
            Log.write("The original chat server details were \(host):\(port)")
            chatProxy.setUpstream(host: host, port: port)
        }
        self.chatProxy = chatProxy
        self.configProxy = configProxy
        self.mainController = mainController

        var riotArguments = ["--client-config-url=http://127.0.0.1:\(configPort)"]
        if let product = game.launchProduct {
            riotArguments += ["--launch-product=\(product)", "--launch-patchline=\(arguments.gamePatchline)", "--allow-direct-launch"]
        }
        if let params = arguments.riotClientParams {
            riotArguments += params.split(separator: " ").map(String.init)
        }
        if let params = arguments.gameParams {
            riotArguments += ["--"] + params.split(separator: " ").map(String.init)
        }

        Log.write("About to launch Riot Client with parameters:\n\(riotArguments.joined(separator: " "))")
        let riotClientPid = try Utils.spawnDisclaimed(path: riotClientPath, arguments: riotArguments)

        // Exit when the Riot Client does, so no ghost Deceive stays around.
        watchRiotClientExit(pid: riotClientPid)
    }

    private static func watchRiotClientExit(pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            source.cancel()
            // Reap our own child, so it can't be mistaken for a relaunched client below. A no-op for other processes.
            waitpid(pid, nil, WNOHANG)
            Log.write("Detected Riot Client exit.")
            // Wait a bit to make sure this is not a relaunch triggered by the Riot Client itself.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if let newPid = Utils.riotClientPid() {
                    Log.write("A new Riot Client process spawned, monitoring that for exits.")
                    watchRiotClientExit(pid: newPid)
                } else {
                    Log.write("No new clients spawned after waiting, exiting.")
                    mainController?.saveStatus()
                    exit(0)
                }
            }
        }
        riotClientWatcher = source
        source.resume()
    }
}
