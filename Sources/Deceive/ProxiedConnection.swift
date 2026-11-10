import Foundation
import Network

/// Bridges one Riot Client chat connection to the real chat server, rewriting presences on the way out
/// and injecting the "Deceive Active!" fake friend on the way in.
final class ProxiedConnection {
    static let fakePlayerJid = "41c322a1-b328-495b-a004-5ccd3e45eae8@eu1.pvp.net"
    private static let rosterQuery = Data("<query xmlns='jabber:iq:riotgames:roster'>".utf8)
    private static let fakePlayerRosterItem: Data = {
        let item: String = [
            "<item jid='\(fakePlayerJid)' name='&#9;Deceive Active!' subscription='both' puuid='41c322a1-b328-495b-a004-5ccd3e45eae8'>",
            "<group priority='9999'>Deceive</group>",
            "<state>online</state>",
            "<id name='&#9;Deceive Active!' tagline='...'/>",
            "<lol name='&#9;Deceive Active!'/>",
            "<platforms><riot name='&#9;Deceive Active' tagline='...'/></platforms>",
            "</item>",
        ].joined()
        return Data(item.utf8)
    }()
    /// A presence that does not parse is buffered until the rest arrives, up to this many bytes.
    private static let maxPendingPresence = 256 * 1024

    private let incoming: NWConnection
    private var outgoing: NWConnection?
    private let chatHost: String
    private let chatPort: Int
    private let settings: Settings
    private let queue = DispatchQueue(label: "deceive.connection")

    // State below is only touched on `queue`.
    private var connected = true
    private var lastPresence: String?
    private var pendingPresence = Data()
    private var insertedFakePlayer = false
    private var sentFakePlayerPresence = false
    private var valorantVersion: String?

    /// Called on the main queue once, when either side disconnects.
    var onClosed: (() -> Void)?
    /// Called on the main queue with messages the player sends to the fake player.
    var onChatMessage: ((String) -> Void)?
    /// Called on the main queue when the real chat server cannot be reached. Call the argument to retry.
    var onUpstreamUnreachable: ((@escaping () -> Void) -> Void)?

    init(incoming: NWConnection, chatHost: String, chatPort: Int, settings: Settings) {
        self.incoming = incoming
        self.chatHost = chatHost
        self.chatPort = chatPort
        self.settings = settings
    }

    func start() {
        incoming.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.connectOutgoing()
            case .failed(let error):
                Log.write("Incoming connection failed: \(error)")
                self?.close()
            case .cancelled:
                self?.close()
            default:
                break
            }
        }
        incoming.start(queue: queue)
    }

    private func connectOutgoing() {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: chatPort)) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(chatHost), port: port, using: .tls)
        outgoing = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.readIncoming()
                self.readOutgoing()
            case .waiting(let error), .failed(let error):
                Log.write("Unable to connect to chat server \(self.chatHost):\(self.chatPort): \(error)")
                connection.stateUpdateHandler = nil
                connection.cancel()
                DispatchQueue.main.async {
                    self.onUpstreamUnreachable? { self.queue.async { if self.connected { self.connectOutgoing() } } }
                }
            case .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: Riot Client -> chat server

    private func readIncoming() {
        incoming.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.handleIncoming(data) }
            if isComplete || error != nil {
                Log.write("Incoming closed. \(error.map { "\($0)" } ?? "")")
                self.close()
            } else if self.connected {
                self.readIncoming()
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        let bytes = pendingPresence + data
        pendingPresence = Data()
        let content = String(decoding: bytes, as: UTF8.self)

        if content.contains("<presence") && settings.enabled {
            Log.write("<!--RC TO SERVER ORIGINAL-->\(content)")
            if !rewriteAndSendPresence(content, targetStatus: settings.status) {
                // Most likely a stanza split across reads; never forward it unmodified.
                if bytes.count < Self.maxPendingPresence {
                    pendingPresence = bytes
                } else {
                    Log.write("Dropping unparseable presence data.")
                }
            }
        } else if content.contains(Self.fakePlayerJid) {
            // Never send anything involving our fake player to the chat server.
            Log.write("<!--RC TO SERVER REMOVED-->\(content)")
            DispatchQueue.main.async { self.onChatMessage?(content) }
        } else {
            sendOutgoing(bytes)
            // Don't log anything that contains a JWT.
            if !content.contains("token>") { Log.write("<!--RC TO SERVER-->\(content)") }
        }

        if insertedFakePlayer && !sentFakePlayerPresence {
            sendFakePlayerPresence()
        }
    }

    /// Returns false if `content` could not be parsed.
    @discardableResult
    private func rewriteAndSendPresence(_ content: String, targetStatus: String) -> Bool {
        let result: PresenceRewriter.Result
        do {
            result = try PresenceRewriter.rewrite(content, targetStatus: targetStatus, connectToMuc: settings.connectToMuc)
        } catch {
            Log.write("Error rewriting presence: \(error)")
            return false
        }

        lastPresence = content
        sendOutgoing(Data(result.xml.utf8))
        Log.write("<!--DECEIVE TO SERVER-->\(result.xml)")

        if valorantVersion == nil, let version = result.valorantVersion {
            valorantVersion = version
            Log.write("Found VALORANT version: \(version)")
            if insertedFakePlayer { sendFakePlayerPresence() }
        }
        return true
    }

    private func sendOutgoing(_ data: Data) {
        outgoing?.send(content: data, completion: .contentProcessed { error in
            if let error { Log.write("Failed to write to chat server: \(error)") }
        })
    }

    // MARK: Chat server -> Riot Client

    private func readOutgoing() {
        outgoing?.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.handleOutgoing(data) }
            if isComplete || error != nil {
                Log.write("Outgoing closed. \(error.map { "\($0)" } ?? "")")
                self.close()
            } else if self.connected {
                self.readOutgoing()
            }
        }
    }

    private func handleOutgoing(_ data: Data) {
        // Insert the fake player into the roster.
        if !insertedFakePlayer, let range = data.range(of: Self.rosterQuery) {
            insertedFakePlayer = true
            Log.write("<!--SERVER TO RC ORIGINAL-->\(String(decoding: data, as: UTF8.self))")
            var modified = data
            modified.insert(contentsOf: Self.fakePlayerRosterItem, at: range.upperBound)
            sendIncoming(modified)
            Log.write("<!--DECEIVE TO RC-->\(String(decoding: modified, as: UTF8.self))")
        } else {
            sendIncoming(data)
            Log.write("<!--SERVER TO RC-->\(String(decoding: data, as: UTF8.self))")
        }
    }

    private func sendIncoming(_ data: Data) {
        incoming.send(content: data, completion: .contentProcessed { error in
            if let error { Log.write("Failed to write to Riot Client: \(error)") }
        })
    }

    // MARK: Fake player

    private func sendFakePlayerPresence() {
        sentFakePlayerPresence = true
        // VALORANT requires a recent version to not display "Version Mismatch".
        let valorantPresence = Data(FakePlayer.valorantPresenceJSON(version: valorantVersion ?? "unknown").utf8)
            .base64EncodedString()
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        let presence =
            "<presence from='\(Self.fakePlayerJid)/RC-Deceive' id='b-\(UUID().uuidString.lowercased())'>" +
            "<games>" +
            "<keystone><st>chat</st><s.t>\(timestamp)</s.t><s.p>keystone</s.p><pty/></keystone>" +
            // No region (s.r) keeps it in the main "League" group rather than "Other Servers".
            "<league_of_legends><st>chat</st><s.t>\(timestamp)</s.t><s.p>league_of_legends</s.p><s.c>live</s.c><p>{&quot;pty&quot;:true}</p></league_of_legends>" +
            "<valorant><st>chat</st><s.t>\(timestamp)</s.t><s.p>valorant</s.p><s.r>PC</s.r><p>\(valorantPresence)</p><pty/></valorant>" +
            "<bacon><st>chat</st><s.t>\(timestamp)</s.t><s.l>bacon_availability_online</s.l><s.p>bacon</s.p></bacon>" +
            "</games>" +
            "<show>chat</show>" +
            "<platform>riot</platform>" +
            "<status/>" +
            "</presence>"

        sendIncoming(Data(presence.utf8))
        Log.write("<!--DECEIVE TO RC-->\(presence)")
    }

    func sendMessageFromFakePlayer(_ message: String) {
        queue.async {
            guard self.insertedFakePlayer, self.connected else { return }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let stamp = formatter.string(from: Date().addingTimeInterval(1))

            let chatMessage = "<message from='\(Self.fakePlayerJid)/RC-Deceive' stamp='\(stamp)' id='fake-\(stamp)' type='chat'>" +
                "<body>\(message)</body></message>"
            self.sendIncoming(Data(chatMessage.utf8))
            Log.write("<!--DECEIVE TO RC-->\(chatMessage)")
        }
    }

    func updateStatus(_ newStatus: String) {
        queue.async {
            guard self.connected, let lastPresence = self.lastPresence else { return }
            self.rewriteAndSendPresence(lastPresence, targetStatus: newStatus)
        }
    }

    private func close() {
        guard connected else { return }
        connected = false
        incoming.cancel()
        outgoing?.cancel()
        DispatchQueue.main.async { self.onClosed?() }
    }
}

enum FakePlayer {
    static func valorantPresenceJSON(version: String) -> String {
        """
        {
         "isValid": true,
         "isIdle": false,
         "queueId": "competitive",
         "provisioningFlow": "Invalid",
         "partyId": "00000000-0000-0000-0000-000000000000",
         "partySize": 1,
         "maxPartySize": 5,
         "partyOwnerMatchScoreAllyTeam": 0,
         "partyOwnerMatchScoreEnemyTeam": 0,
         "premierPresenceData":
         {
             "rosterId": "",
             "rosterName": "Deceive is active. Ignore any version mismatch warnings.",
             "rosterTag": "Deceive Active!",
             "rosterType": "VCT",
             "division": 0,
             "score": 0,
             "plating": 0,
             "showAura": false,
             "showTag": true,
             "showPlating": false
         },
         "matchPresenceData":
         {
             "sessionLoopState": "MENUS",
             "provisioningFlow": "Invalid",
             "matchMap": "",
             "queueId": "competitive"
         },
         "partyPresenceData":
         {
             "partyId": "00000000-0000-0000-0000-000000000000",
             "isPartyOwner": true,
             "partyState": "DEFAULT",
             "partyAccessibility": "CLOSED",
             "partyLFM": false,
             "partyClientVersion": "\(version)",
             "partyVersion": 1768830115681,
             "partySize": 1,
             "queueEntryTime": "0001.01.01-00.00.00",
             "isPartyCrossPlayEnabled": false,
             "isPlayerCrossPlayEnabled": false,
             "partyPrecisePlatformTypes": 1,
             "customGameName": "Deceive Active!",
             "customGameTeam": "",
             "maxPartySize": 5,
             "tournamentId": "",
             "rosterId": "",
             "partyOwnerSessionLoopState": "MENUS",
             "partyOwnerMatchMap": "",
             "partyOwnerProvisioningFlow": "Invalid",
             "partyOwnerMatchScoreAllyTeam": 0,
             "partyOwnerMatchScoreEnemyTeam": 0
         },
         "playerPresenceData":
         {
             "playerCardId": "893deca1-4123-9c1f-2985-aa9de74cb512",
             "playerTitleId": "e3ca05a4-4e44-9afe-3791-7d96ca8f71fa",
             "accountLevel": 999,
             "competitiveTier": 0,
             "leaderboardPosition": 0
         }
        }
        """
    }
}
