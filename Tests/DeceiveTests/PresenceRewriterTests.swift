import XCTest
@testable import Deceive

final class PresenceRewriterTests: XCTestCase {
    private let presence =
        "<presence id='presence_1'>" +
        "<show>chat</show><status>hello</status>" +
        "<games>" +
        "<league_of_legends><st>chat</st><s.t>1</s.t><m>lobby</m><p>{&quot;championId&quot;:1}</p></league_of_legends>" +
        "<keystone><st>chat</st></keystone>" +
        "<teamfighttactics><st>chat</st></teamfighttactics>" +
        "</games>" +
        "</presence>"

    func testOfflineRemovesGamesAndStatus() throws {
        let result = try PresenceRewriter.rewrite(presence, targetStatus: "offline", connectToMuc: true)
        XCTAssertTrue(result.xml.contains("<show>offline</show>"))
        XCTAssertFalse(result.xml.contains("<status>"))
        XCTAssertFalse(result.xml.contains("league_of_legends"))
        XCTAssertFalse(result.xml.contains("keystone"))
        XCTAssertFalse(result.xml.contains("teamfighttactics"))
    }

    func testMobileKeepsLeagueWithoutDetails() throws {
        let result = try PresenceRewriter.rewrite(presence, targetStatus: "mobile", connectToMuc: true)
        XCTAssertTrue(result.xml.contains("<show>mobile</show>"))
        XCTAssertTrue(result.xml.contains("<league_of_legends><st>mobile</st><s.t>1</s.t></league_of_legends>"))
    }

    func testOnlineKeepsEverything() throws {
        let result = try PresenceRewriter.rewrite(presence, targetStatus: "chat", connectToMuc: true)
        XCTAssertTrue(result.xml.contains("<status>hello</status>"))
        XCTAssertTrue(result.xml.contains("<m>lobby</m>"))
        XCTAssertTrue(result.xml.contains("championId"))
    }

    func testOnlineKeepsInGameDnd() throws {
        let inGame = presence.replacingOccurrences(of: "<league_of_legends><st>chat</st>", with: "<league_of_legends><st>dnd</st>")
            .replacingOccurrences(of: "<show>chat</show>", with: "<show>dnd</show>")
        let result = try PresenceRewriter.rewrite(inGame, targetStatus: "chat", connectToMuc: true)
        XCTAssertTrue(result.xml.contains("<show>dnd</show>"))
        XCTAssertTrue(result.xml.contains("<st>dnd</st>"))
    }

    func testLobbyPresenceDependsOnMucSetting() throws {
        let muc = "<presence to='lobby@champ-select.eu1.pvp.net/me'><show>chat</show></presence>"
        XCTAssertEqual(try PresenceRewriter.rewrite(muc, targetStatus: "offline", connectToMuc: false).xml, "")
        XCTAssertTrue(try PresenceRewriter.rewrite(muc, targetStatus: "offline", connectToMuc: true).xml.contains("<show>chat</show>"))
    }

    func testOtherStanzasArePreserved() throws {
        let result = try PresenceRewriter.rewrite("<iq type='get' id='1'/>" + presence, targetStatus: "offline", connectToMuc: true)
        XCTAssertTrue(result.xml.hasPrefix("<iq type=\"get\" id=\"1\"/>"))
    }

    func testExtractsValorantVersion() throws {
        let json = #"{"partyPresenceData":{"partyClientVersion":"release-09.11"}}"#
        let encoded = Data(json.utf8).base64EncodedString()
        let stanza = "<presence><show>chat</show><games><valorant><st>chat</st><p>\(encoded)</p></valorant></games></presence>"
        let result = try PresenceRewriter.rewrite(stanza, targetStatus: "offline", connectToMuc: true)
        XCTAssertEqual(result.valorantVersion, "release-09.11")
        XCTAssertFalse(result.xml.contains("valorant"))
    }

    func testIncompleteStanzaThrows() {
        XCTAssertThrowsError(try PresenceRewriter.rewrite("<presence><show>chat</sh", targetStatus: "offline", connectToMuc: true))
    }
}

final class ProxyCertificateTests: XCTestCase {
    func testDERParsesNestedSequences() throws {
        // SEQUENCE { INTEGER 1, OCTET STRING 0xAB }
        let nodes = try DER.parse([0x30, 0x06, 0x02, 0x01, 0x01, 0x04, 0x01, 0xAB])
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].children.map(\.tag), [0x02, 0x04])
        XCTAssertEqual(nodes[0].children[1].content, [0xAB])
    }

    /// Set DECEIVE_TEST_PFX to a downloaded copy of https://mln.cx/deceive/localhost.pfx to run this.
    func testLoadsUpstreamCertificate() throws {
        guard let path = ProcessInfo.processInfo.environment["DECEIVE_TEST_PFX"] else {
            throw XCTSkip("DECEIVE_TEST_PFX not set")
        }
        let identity = try ProxyCertificate.load(pfx: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(SecCertificateCopySubjectSummary(identity.chain[0]) as String?, ConfigProxy.localhostDomain)
        XCTAssertNotNil(identity.notAfter)
    }
}

final class UtilsTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(Utils.isVersion("v1.0.1", newerThan: "v1.0.0"))
        XCTAssertTrue(Utils.isVersion("v1.10.0", newerThan: "v1.9.9"))
        XCTAssertTrue(Utils.isVersion("v2", newerThan: "v1.9.9"))
        XCTAssertFalse(Utils.isVersion("v1.0.0", newerThan: "v1.0.0"))
        XCTAssertFalse(Utils.isVersion("v1.0", newerThan: "v1.0.0"))
        XCTAssertFalse(Utils.isVersion("v0.9.0", newerThan: "v1.0.0"))
    }

    func testPreReleaseVersionComparison() {
        XCTAssertTrue(Utils.isVersion("v1.0.0", newerThan: "v1.0.0-beta.1"))
        XCTAssertFalse(Utils.isVersion("v1.0.0-beta.1", newerThan: "v1.0.0"))
        XCTAssertTrue(Utils.isVersion("v1.0.0-beta.2", newerThan: "v1.0.0-beta.1"))
        XCTAssertTrue(Utils.isVersion("v1.0.0-beta.10", newerThan: "v1.0.0-beta.9"))
        XCTAssertTrue(Utils.isVersion("v1.0.0-rc.1", newerThan: "v1.0.0-beta.3"))
        XCTAssertTrue(Utils.isVersion("v1.0.1-beta.1", newerThan: "v1.0.0"))
        XCTAssertFalse(Utils.isVersion("v1.0.0-beta.1", newerThan: "v1.0.0-beta.1"))
    }
}
