import Foundation
import XCTest
@testable import WatchDotCore

private let voiceProbeNow = Date(timeIntervalSince1970: 1_800_000_000)

private func voiceProbeJWT(_ claims: [String: Any]) throws -> String {
    "fixture.\(try JSONSerialization.data(withJSONObject: claims).base64URL).fixture"
}

private func voiceProbeAccount(accountID: String = "account-fixture", boundAccountID: String = "account-fixture",
                               expired: Bool = false) throws -> SignedInAccount {
    let access: [String: Any] = ["exp": voiceProbeNow.addingTimeInterval(expired ? -1 : 3600).timeIntervalSince1970,
        "https://api.openai.com/auth": ["chatgpt_account_id": accountID, "user_id": "user-fixture"]]
    let identity: [String: Any] = ["sub": "subject-fixture",
        "https://api.openai.com/auth": ["chatgpt_account_id": boundAccountID, "user_id": "user-fixture"]]
    return SignedInAccount(subject: "subject-fixture", clientID: OpenAIOAuthClient.codex, email: nil,
        expiresAt: voiceProbeNow.addingTimeInterval(3600), idToken: try voiceProbeJWT(identity),
        accessToken: try voiceProbeJWT(access))
}

private func voicePrimary(threadID: String = "thread-fixture", dotID: String = "dot-fixture",
                          available: Bool = true) -> [String: Any] {
    ["selection": ["available": available, "thread_id": threadID,
                   "aeon_id": dotID, "messaging_room_id": "room-fixture"],
     "profile": ["id": dotID, "active_root_thread_id": threadID, "aeon_kind": "orbit"]]
}

private func voiceMetadata(threadID: String = "thread-fixture", threadSource: String? = "aeon") -> [String: Any] {
    var thread: [String: Any] = ["id": threadID, "PRIVATE-UNKNOWN-KEY": "PRIVATE-SERVER-BODY"]
    if let threadSource { thread["threadSource"] = threadSource }
    return ["thread": thread, "PRIVATE-UNKNOWN-KEY": "PRIVATE-SERVER-BODY"]
}

private actor VoiceProbeHTTP: SignInHTTP {
    let replies: [SignInHTTPResponse]
    let onResponse: (@Sendable (Int) async -> Void)?
    var requests: [URLRequest] = []
    init(_ replies: [SignInHTTPResponse], onResponse: (@Sendable (Int) async -> Void)? = nil) {
        self.replies = replies; self.onResponse = onResponse
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let result = try await sendWithMetadata(request)
        return (result.data, result.status)
    }
    func sendWithMetadata(_ request: URLRequest) async throws -> SignInHTTPResponse {
        let index = requests.count
        requests.append(request)
        guard index < replies.count else { throw URLError(.notConnectedToInternet) }
        await onResponse?(index)
        return replies[index]
    }
    func captured() -> [URLRequest] { requests }
}

private actor VoiceProbeAccountFence {
    var current = true
    func allows() -> Bool { current }
    func changeAccount() { current = false }
}

@MainActor
final class DotVoiceRouteProbeTests: XCTestCase {
    private func response(_ value: [String: Any], status: Int = 200,
                          challenge: Bool = false) throws -> SignInHTTPResponse {
        SignInHTTPResponse(data: try JSONSerialization.data(withJSONObject: value), status: status,
                           contentType: .json, clientChallenge: challenge)
    }

    func testReadsPrimaryAndExactCloudMetadataWithoutOpeningVoiceOrReturningIdentifiers() async throws {
        let http = VoiceProbeHTTP(try [response(voicePrimary()), response(voiceMetadata())])
        let result = try await DotVoiceRouteProbe(http: http).run(
            account: voiceProbeAccount(), now: voiceProbeNow, isCurrentAccount: { true })
        XCTAssertEqual(result.capability, .cloudAeonMetadataVerified)
        XCTAssertTrue(result.messagingRoomLinked)
        XCTAssertFalse(result.voiceCallValidated)
        let requests = await http.captured()
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
            "https://chatgpt.com/backend-api/tbo/primary",
            "https://codex-cloud-backend.chatgpt.com/v1/threads/thread-fixture"])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil && !$0.httpShouldHandleCookies })
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-OpenAI-Product-Sku"), "aeon")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-fixture" })
        let publicOutput = String(decoding: try JSONEncoder().encode(result), as: UTF8.self) + result.capability.message
        for value in ["thread-fixture", "dot-fixture", "room-fixture", "account-fixture", "PRIVATE", "Bearer", "fixture."] {
            XCTAssertFalse(publicOutput.contains(value))
        }
    }

    func testNullSelectionFallsBackToProfileActiveRootAsShippedClientDoes() async throws {
        let primary: [String: Any] = ["selection": NSNull(), "profile": [
            "id": "dot-fixture", "active_root_thread_id": "thread-fixture", "aeon_kind": "orbit"]]
        let http = VoiceProbeHTTP(try [response(primary), response(voiceMetadata())])
        let result = try await DotVoiceRouteProbe(http: http).run(
            account: voiceProbeAccount(), now: voiceProbeNow, isCurrentAccount: { true })
        XCTAssertEqual(result.capability, .cloudAeonMetadataVerified)
        XCTAssertFalse(result.messagingRoomLinked)
    }

    func testAbsentThreadSourceNeverClaimsAeonFromAnotherSourceField() async throws {
        var metadata = voiceMetadata(threadSource: nil)
        metadata["thread"] = ["id": "thread-fixture", "source": "aeon"]
        let http = VoiceProbeHTTP(try [response(voicePrimary()), response(metadata)])
        let result = try await DotVoiceRouteProbe(http: http).run(
            account: voiceProbeAccount(), now: voiceProbeNow, isCurrentAccount: { true })
        XCTAssertEqual(result.capability, .cloudThreadMetadataKindUnverified)
        XCTAssertFalse(result.voiceCallValidated)
    }

    func testLocateReturnsInMemoryBindingOnlyForVerifiedAeonWithoutDuplicateDiscovery() async throws {
        for thread in [["id": "thread-fixture", "threadSource": "aeon"],
                       ["id": "thread-fixture", "threadStartKind": "aeon"]] {
            let http = VoiceProbeHTTP(try [response(voicePrimary()), response(["thread": thread])])
            let located = try await DotVoiceRouteProbe(http: http).locate(
                account: voiceProbeAccount(), now: voiceProbeNow, isCurrentAccount: { true })
            XCTAssertEqual(located.diagnostics.capability, .cloudAeonMetadataVerified)
            let route = try XCTUnwrap(located.route)
            XCTAssertEqual(route.dotID, "dot-fixture")
            XCTAssertEqual(route.threadID, "thread-fixture")
            XCTAssertEqual(route.accountID, "account-fixture")
            XCTAssertEqual(route.subject, "subject-fixture")
            XCTAssertEqual(route.hostID, "durable")
            let requests = await http.captured()
            XCTAssertEqual(requests.count, 2)
        }
        let http = VoiceProbeHTTP(try [response(voicePrimary()), response(voiceMetadata(threadSource: nil))])
        let located = try await DotVoiceRouteProbe(http: http).locate(
            account: voiceProbeAccount(), now: voiceProbeNow, isCurrentAccount: { true })
        XCTAssertNil(located.route)
        XCTAssertEqual(located.diagnostics.capability, .cloudThreadMetadataKindUnverified)
        try await expect(.threadKind, replies: [response(voicePrimary()), response([
            "thread": ["id": "thread-fixture", "threadSource": "cli", "threadStartKind": "aeon"]])], expectedCalls: 2)
    }

    func testUnavailableSelectionAndMismatchedTBOStopBeforeCloudRequest() async throws {
        var mismatch = voicePrimary()
        mismatch["profile"] = ["id": "another-dot", "active_root_thread_id": "another-thread"]
        for (body, expected) in [(voicePrimary(available: false), DotVoiceRouteProbeError.unavailable),
                                 (mismatch, .binding), (["selection": NSNull()], .noPrimary),
                                 (["error": "PRIVATE-SERVER-BODY"], .schema)] {
            try await expect(expected, replies: [response(body)], expectedCalls: 1)
        }
    }

    func testMetadataMustMatchRequestedThreadAndExplicitAeonKind() async throws {
        try await expect(.binding, replies: [response(voicePrimary()), response(voiceMetadata(threadID: "another-thread"))], expectedCalls: 2)
        try await expect(.threadKind, replies: [response(voicePrimary()), response(voiceMetadata(threadSource: "cli"))], expectedCalls: 2)
    }

    func testOpaqueThreadIDCannotChangeOriginQueryFragmentOrPathSegments() async throws {
        for (id, encoded) in [("thread/child?x=y#z", "thread%2Fchild%3Fx%3Dy%23z"),
                              ("%2fother", "%252fother"), ("https://example.invalid", "https%3A%2F%2Fexample.invalid"),
                              ("hilo:ñ", "hilo%3A%C3%B1")] {
            let http = VoiceProbeHTTP(try [response(voicePrimary(threadID: id)), response(voiceMetadata(threadID: id))])
            _ = try await DotVoiceRouteProbe(http: http).run(account: voiceProbeAccount(), now: voiceProbeNow, isCurrentAccount: { true })
            let requests = await http.captured()
            let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.host, "codex-cloud-backend.chatgpt.com")
            XCTAssertEqual(components.percentEncodedPath, "/v1/threads/\(encoded)")
            XCTAssertNil(components.query); XCTAssertNil(components.fragment)
        }
        for id in ["", " ", ".", "..", "thread\r\nCookie: x", String(repeating: "x", count: 4097)] {
            try await expect(.identifier, replies: [response(voicePrimary(threadID: id))], expectedCalls: 1)
        }
    }

    func testRejectsExpiredAndMismatchedAccountsBeforeNetwork() async throws {
        try await expect(.session, replies: [], account: voiceProbeAccount(expired: true), expectedCalls: 0)
        try await expect(.identity, replies: [], account: voiceProbeAccount(boundAccountID: "another-account"), expectedCalls: 0)
        try await expect(.identity, replies: [], account: voiceProbeAccount(accountID: "account\r\nX: x"), expectedCalls: 0)
        let http = VoiceProbeHTTP([])
        do {
            _ = try await DotVoiceRouteProbe(http: http).run(account: voiceProbeAccount(), now: voiceProbeNow, isCurrentAccount: { false })
            XCTFail("A changed account must stop before any request")
        } catch { XCTAssertEqual(error as? DotVoiceRouteProbeError, .accountChanged) }
        let requests = await http.captured()
        XCTAssertTrue(requests.isEmpty)
    }

    func testAccountChangeDuringPrimaryReadPreventsCrossAccountCloudRequest() async throws {
        let fence = VoiceProbeAccountFence()
        let http = VoiceProbeHTTP(try [response(voicePrimary())], onResponse: { _ in await fence.changeAccount() })
        do {
            _ = try await DotVoiceRouteProbe(http: http).run(account: voiceProbeAccount(), now: voiceProbeNow,
                                                           isCurrentAccount: { await fence.allows() })
            XCTFail("Changed account must not continue")
        } catch { XCTAssertEqual(error as? DotVoiceRouteProbeError, .accountChanged) }
        let requests = await http.captured()
        XCTAssertEqual(requests.count, 1)
    }

    func testRedirectsChallengesAndErrorBodiesNeverBecomeSuccessOrEchoServerText() async throws {
        for status in [301, 302, 307, 308, 401, 403, 429, 500] {
            try await expect(.primaryHTTP(status), replies: [response(["error": "PRIVATE-SERVER-BODY"], status: status)], expectedCalls: 1)
        }
        try await expect(.challenge, replies: [response(voicePrimary(), challenge: true)], expectedCalls: 1)
        try await expect(.cloudHTTP(403), replies: [response(voicePrimary()), response(["error": "PRIVATE-SERVER-BODY"], status: 403)], expectedCalls: 2)
        try await expect(.schema, replies: [response(voicePrimary()), response(["error": "PRIVATE-SERVER-BODY"])], expectedCalls: 2)
        for error in [DotVoiceRouteProbeError.binding, .schema, .network, .identity, .cloudHTTP(403)] {
            XCTAssertFalse(error.message.contains("PRIVATE-SERVER-BODY"))
        }
    }

    private func expect(_ expected: DotVoiceRouteProbeError, replies: [SignInHTTPResponse],
                        account: SignedInAccount? = nil, expectedCalls: Int) async throws {
        let http = VoiceProbeHTTP(replies)
        do {
            _ = try await DotVoiceRouteProbe(http: http).run(account: try account ?? voiceProbeAccount(),
                                                           now: voiceProbeNow, isCurrentAccount: { true })
            XCTFail("Expected safe failure \(expected)")
        } catch { XCTAssertEqual(error as? DotVoiceRouteProbeError, expected) }
        let requests = await http.captured()
        XCTAssertEqual(requests.count, expectedCalls)
    }
}
