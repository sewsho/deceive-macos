/// Which game to automatically launch when Deceive is started.
/// Only the games that the Riot Client ships on macOS are offered.
enum LaunchGame: String, CaseIterable {
    /// Attempt to start League of Legends.
    case lol = "LoL"
    /// Attempt to start Teamfight Tactics.
    case teamfightTactics = "TeamfightTactics"
    /// Attempt to launch the Riot Client.
    case riotClient = "RiotClient"
    /// Display a dialog asking which game to launch.
    case prompt = "Prompt"
    /// Use the persisted default launch game, or prompt if there is none.
    case auto = "Auto"

    init?(argument: String) {
        let lowered = argument.lowercased()
        if let match = LaunchGame.allCases.first(where: { $0.rawValue.lowercased() == lowered }) {
            self = match
            return
        }
        switch lowered {
        case "league", "league_of_legends": self = .lol
        case "tft", "teamfighttactics": self = .teamfightTactics
        case "rc", "riot_client": self = .riotClient
        default: return nil
        }
    }

    /// The `--launch-product` value for the Riot Client, or nil to only open the Riot Client.
    var launchProduct: String? {
        switch self {
        case .lol: return "league_of_legends"
        case .teamfightTactics: return "teamfighttactics"
        case .riotClient, .prompt, .auto: return nil
        }
    }
}
