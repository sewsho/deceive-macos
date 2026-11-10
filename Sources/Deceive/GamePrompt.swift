import AppKit

enum GamePrompt {
    private static let choices: [(title: String, game: LaunchGame)] = [
        ("League of Legends", .lol),
        ("Teamfight Tactics", .teamfightTactics),
        ("Riot Client", .riotClient),
    ]

    /// Asks which game to launch. Returns nil if the user cancelled.
    @MainActor
    static func show() -> LaunchGame? {
        let alert = NSAlert()
        alert.messageText = Utils.title
        alert.informativeText = "Which game would you like to launch?"
        choices.forEach { alert.addButton(withTitle: $0.title) }
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember my decision and skip this screen on future launches."

        NSApp.activate(ignoringOtherApps: true)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard choices.indices.contains(index) else { return nil }

        let game = choices[index].game
        if alert.suppressionButton?.state == .on {
            Persistence.setDefaultLaunchGame(game)
        }
        return game
    }
}
