import CryptoKit
import Foundation
import XCTest
@testable import WatchDotCore

private actor DeviceHTTPFixture: SignInHTTP {
    var replies: [(Data, Int)]
    var requests: [URLRequest] = []
    init(_ replies: [(Data, Int)]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        guard !replies.isEmpty else { throw SignInError.unavailable }
        return replies.removeFirst()
    }
    func captured() -> [URLRequest] { requests }
}
@MainActor
private final class DeviceStoreFixture: SignInStore {
    var record: SignInRecord?
    var fails = false
    func load() throws -> SignInRecord? { record }
    func save(_ value: SignInRecord) throws {
        if fails { throw SignInError.storage }
        record = value
    }
}

@MainActor
final class DeviceAuthorizationTests: XCTestCase {
    private func reply(_ value: [String: Any], _ status: Int = 200) throws -> (Data, Int) {
        (try JSONSerialization.data(withJSONObject: value), status)
    }
    private func challenge(_ http: DeviceHTTPFixture) async throws -> DeviceAuthorizationChallenge {
        try await DeviceAuthorizationService(http: http).begin(now: .now)
    }
    private var code: [String: Any] { ["device_auth_id": "fixture-device", "user_code": "TEST-CODE0", "interval": "3"] }

    func testPendingNeverExchangesOrReturnsTokens() async throws {
        let http = DeviceHTTPFixture([try reply(code), (Data(), 403), (Data(), 404)])
        let c = try await challenge(http), service = DeviceAuthorizationService(http: http)
        let first = try await service.poll(c, now: .now)
        let second = try await service.poll(c, now: .now)
        XCTAssertNil(first); XCTAssertNil(second)
        let paths = await http.captured().compactMap { $0.url?.path }
        XCTAssertEqual(paths, ["/api/accounts/deviceauth/usercode", "/api/accounts/deviceauth/token", "/api/accounts/deviceauth/token"])
    }
    func testRejectsBadPKCEBeforeTokenExchange() async throws {
        let grant = ["authorization_code": "fixture-code", "code_challenge": "wrong", "code_verifier": String(repeating: "x", count: 43)]
        let http = DeviceHTTPFixture([try reply(code), try reply(grant)])
        let c = try await challenge(http)
        do { _ = try await DeviceAuthorizationService(http: http).poll(c, now: .now); XCTFail("unbound grant") }
        catch SignInError.invalidResponse {} catch { XCTFail("unexpected \(error)") }
        let count = await http.captured().count
        XCTAssertEqual(count, 2)
    }
    func testExpiredChallengeDoesNotSendPoll() async throws {
        let http = DeviceHTTPFixture([try reply(code)])
        let c = try await challenge(http)
        do { _ = try await DeviceAuthorizationService(http: http).poll(c, now: c.expiresAt); XCTFail("expired") }
        catch SignInError.expired {} catch { XCTFail("unexpected \(error)") }
        let count = await http.captured().count
        XCTAssertEqual(count, 1)
    }
    func testSignedDeviceIdentityAndRefreshSession() async throws {
        let signer = try SigningFixture()
        let token = try signer.token(nonce: "unused", client: OpenAIOAuthClient.codex, changes: ["nonce": NSNull()])
        let verifier = String(repeating: "a", count: 43)
        let grant = ["authorization_code": "test+code", "code_verifier": verifier,
                     "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL]
        let tokens: [String: Any] = ["id_token": token, "access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 1800]
        let http = DeviceHTTPFixture([try reply(code), try reply(grant), try reply(tokens), (signer.jwks, 200)])
        let c = try await challenge(http)
        let account = try await DeviceAuthorizationService(http: http).poll(c, now: .now)
        XCTAssertEqual(account?.subject, "test-subject")
        XCTAssertEqual(account?.refreshToken, "fixture-refresh")
        XCTAssertNil(account?.authorizationNonce)
        let requests = await http.captured()
        XCTAssertEqual(requests[2].url?.absoluteString, "https://auth.openai.com/oauth/token")
        let body = String(decoding: try XCTUnwrap(requests[2].httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("code=test%2Bcode"))
        XCTAssertTrue(body.contains("redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback"))
    }
    func testDeviceVerificationPreservesSignatureAudienceAndNonceChecks() throws {
        let signer = try SigningFixture(), other = try SigningFixture()
        let valid = try signer.token(nonce: "unused", client: OpenAIOAuthClient.codex, changes: ["nonce": NSNull()])
        XCTAssertThrowsError(try OpenAIIdentityVerifier.verifyDeviceCode(valid, jwks: other.jwks, clientID: OpenAIOAuthClient.codex, now: .now))
        XCTAssertThrowsError(try OpenAIIdentityVerifier.verifyDeviceCode(valid, jwks: signer.jwks, clientID: "wrong-client", now: .now))
        let withNonce = try signer.token(nonce: "unexpected", client: OpenAIOAuthClient.codex)
        XCTAssertThrowsError(try OpenAIIdentityVerifier.verifyDeviceCode(withNonce, jwks: signer.jwks, clientID: OpenAIOAuthClient.codex, now: .now))
    }
    func testBadIntervalCannotCreateBusyPolling() async throws {
        for value in ["0", "nan", "10000"] {
            var response = code; response["interval"] = value
            let http = DeviceHTTPFixture([try reply(response)])
            do { _ = try await challenge(http); XCTFail("bad interval") } catch {}
        }
    }
    func testKeychainSaveMustSucceedAndAccountCannotSwitchSilently() throws {
        let store = DeviceStoreFixture(), session = ConnectionSession(store: store)
        func account(_ subject: String) -> SignedInAccount {
            SignedInAccount(subject: subject, clientID: OpenAIOAuthClient.codex, email: nil,
                expiresAt: Date().addingTimeInterval(3600), idToken: "fixture", accessToken: "fixture", refreshToken: "fixture")
        }
        store.fails = true
        XCTAssertThrowsError(try session.acceptDeviceAccount(account("first")))
        XCTAssertNil(store.record?.account)
        store.fails = false
        try session.acceptDeviceAccount(account("first"))
        XCTAssertEqual(session.phase, .signedIn)
        XCTAssertThrowsError(try session.acceptDeviceAccount(account("other")))
        XCTAssertEqual(store.record?.account?.subject, "first")
    }
}
