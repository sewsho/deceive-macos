import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = LaunchArguments(Array(CommandLine.arguments.dropFirst()))
        Task { @MainActor in await StartupHandler.start(arguments) }
    }
}

// Keep App Nap from throttling the proxy while it sits in the background.
let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                     reason: "Proxying Riot chat")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu bar only, no Dock icon. The bundled Info.plist also sets LSUIElement.
app.setActivationPolicy(.accessory)
app.run()
