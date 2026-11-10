import Foundation

/// Rewrites outgoing XMPP presence stanzas so that the player appears with the chosen status.
enum PresenceRewriter {
    struct Result {
        let xml: String
        /// The VALORANT client version found in the player's own presence, if any.
        let valorantVersion: String?
    }

    /// Rewrites every `<presence>` stanza in `content` to `targetStatus` ("chat", "offline" or "mobile").
    /// Throws if `content` is not a sequence of complete XML elements.
    static func rewrite(_ content: String, targetStatus: String, connectToMuc: Bool) throws -> Result {
        let document = try XMLDocument(xmlString: "<xml>" + content + "</xml>", options: [])
        guard let root = document.rootElement() else { throw CocoaError(.formatting) }

        var valorantVersion: String?

        for presence in root.elements(forName: "presence") {
            // Presences addressed to someone are for group chats (lobbies, champ select).
            if presence.attribute(forName: "to") != nil {
                if connectToMuc { continue }
                presence.detach()
                continue
            }

            let games = presence.child("games")
            let league = games?.child("league_of_legends")

            if targetStatus != "chat" || league?.child("st")?.stringValue != "dnd" {
                presence.child("show")?.stringValue = targetStatus
                league?.child("st")?.stringValue = targetStatus
            }

            if targetStatus == "chat" { continue }
            presence.child("status")?.detach()

            if targetStatus == "mobile" {
                league?.child("p")?.detach()
                league?.child("m")?.detach()
            } else {
                league?.detach()
            }

            // Legends of Runeterra, 2XKO, Riot Client and Teamfight Tactics.
            for game in ["bacon", "lion", "keystone", "riot_client", "teamfighttactics"] {
                games?.child(game)?.detach()
            }

            // Keep the VALORANT version so the fake player does not show "Version Mismatch".
            if valorantVersion == nil,
               let encoded = games?.child("valorant")?.child("p")?.stringValue,
               let decoded = Data(base64Encoded: encoded),
               let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
               let party = json["partyPresenceData"] as? [String: Any] {
                valorantVersion = party["partyClientVersion"] as? String
            }
            games?.child("valorant")?.detach()
        }

        let xml = (root.children ?? [])
            .compactMap { $0 as? XMLElement }
            .map { $0.xmlString(options: [.nodeCompactEmptyElement]) }
            .joined()
        return Result(xml: xml, valorantVersion: valorantVersion)
    }
}

private extension XMLElement {
    func child(_ name: String) -> XMLElement? { elements(forName: name).first }
}
