import Foundation
import XCTest
@testable import WatchDotCore

private let managedNow = Date(timeIntervalSince1970: 1_800_000_000)
private let managedOffer = "v=0\r\ns=synthetic-offer\r\n"

private actor ManagedRouteHTTP: SignInHTTP {
    func send(_ request: URLRequest) throws -> (Data, Int) {
        let body: [String: Any] = request.url?.host == "chatgpt.com"
            ? ["selection": ["available": true, "thread_id": "selected-fixture", "aeon_id": "dot-fixture"],
               "profile": ["id": "dot-fixture", "active_root_thread_id": "root-fixture"]]
            : ["thread": ["id": "selected-fixture", "threadSource": "aeon"]]
        return (try JSONSerialization.data(withJSONObject: body), 200)
    }
}

private actor ManagedFence {
    var current = true
    func allows() -> Bool { current }
    func change() { current = false }
}

private actor ManagedHTTP: SignInHTTP {
    var requests: [URLRequest] = []
    let createStatus: Int, attachStatus: Int
    let root: String, answer: String
    let holdCreate: Bool, holdAttach: Bool
    var createWaiter: CheckedContinuation<Void, Never>?
    var attachWaiter: CheckedContinuation<Void, Never>?
    init(createStatus: Int = 201, attachStatus: Int = 204, root: String = "root-fixture",
         answer: String = "v=0\r\ns=synthetic-answer\r\n", holdCreate: Bool = false, holdAttach: Bool = false) {
        self.createStatus = createStatus; self.attachStatus = attachStatus; self.root = root
        self.answer = answer; self.holdCreate = holdCreate; self.holdAttach = holdAttach
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let result = try await sendWithMetadata(request); return (result.data, result.status)
    }
    func sendWithMetadata(_ request: URLRequest) async throws -> SignInHTTPResponse {
        requests.append(request)
        if request.url!.path.hasSuffix("/attach") {
            if holdAttach { await withCheckedContinuation { attachWaiter = $0 } }
            return SignInHTTPResponse(data: Data("PRIVATE-SERVER-TEXT".utf8), status: attachStatus)
        }
        if request.url!.path.hasSuffix("/stop") { return SignInHTTPResponse(data: Data(), status: 204) }
        if holdCreate { await withCheckedContinuation { createWaiter = $0 } }
        return SignInHTTPResponse(data: Data(answer.utf8), status: createStatus,
            location: "/tbo/dot-fixture/voice/calls/rtc_fixture?private=not-exported", rootThreadID: root)
    }
    func finishCreate() { createWaiter?.resume(); createWaiter = nil }
    func finishAttach() { attachWaiter?.resume(); attachWaiter = nil }
    func waitingForCreate() -> Bool { createWaiter != nil }
    func waitingForAttach() -> Bool { attachWaiter != nil }
    func snapshot() -> [URLRequest] { requests }
}

private final class ManagedDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DotManagedVoiceDiagnostic] = []
    func append(_ value: DotManagedVoiceDiagnostic) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [DotManagedVoiceDiagnostic] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor
final class DotManagedVoiceCallTests: XCTestCase {
    private func make(_ http: ManagedHTTP, fence: ManagedFence = ManagedFence(),
                      diagnostics: ManagedDiagnostics = ManagedDiagnostics()) async throws -> DotManagedVoiceCall {
        func jwt(_ body: [String: Any]) throws -> String {
            "fixture.\(try JSONSerialization.data(withJSONObject: body, options: .sortedKeys).base64URL).fixture"
        }
        let auth = ["chatgpt_account_id": "account-fixture", "user_id": "user-fixture"]
        let account = SignedInAccount(subject: "subject-fixture", clientID: OpenAIOAuthClient.codex, email: nil,
            expiresAt: managedNow.addingTimeInterval(3600),
            idToken: try jwt(["sub": "subject-fixture", "https://api.openai.com/auth": auth]),
            accessToken: try jwt(["exp": managedNow.addingTimeInterval(3600).timeIntervalSince1970, "https://api.openai.com/auth": auth]))
        let route = try await DotVoiceRouteProbe(http: ManagedRouteHTTP()).locate(account: account,
            now: managedNow, isCurrentAccount: { true }).route
        return DotManagedVoiceCall(http: http, account: account, route: try XCTUnwrap(route),
            isCurrentAccount: { await fence.allows() }, onDiagnostic: { diagnostics.append($0) }, now: { managedNow })
    }

    func testCreatesAttachesAndStopsOnlyOwnDotWithNoPromptOrModelOverrides() async throws {
        let http = ManagedHTTP(), call = try await make(http)
        let allocation = try await call.allocate(offer: managedOffer)
        XCTAssertTrue(allocation.answer.hasPrefix("v=0"))
        try await call.attach()
        await call.stop(); await call.stop()
        let requests = await http.snapshot()
        XCTAssertEqual(requests.map { $0.url!.path }, ["/backend-api/tbo/dot-fixture/voice/calls",
            "/backend-api/tbo/dot-fixture/voice/calls/rtc_fixture/attach", "/backend-api/tbo/dot-fixture/voice/calls/rtc_fixture/stop"])
        for request in requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "chatgpt.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-fixture")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer fixture.") == true)
            XCTAssertFalse(request.httpShouldHandleCookies)
        }
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody)) as! [String: String]
        XCTAssertEqual(body, ["sdp": managedOffer])
        XCTAssertNil(requests[1].httpBody); XCTAssertNil(requests[2].httpBody)
    }

    func testRootMismatchKeepsOwnAllocationForCleanupButCannotAttach() async throws {
        let http = ManagedHTTP(root: "another-root"), call = try await make(http)
        do { _ = try await call.allocate(offer: managedOffer); XCTFail("Root mismatch") }
        catch { XCTAssertEqual(error as? DotManagedVoiceError, .rootChanged) }
        do { try await call.attach(); XCTFail("Unverified allocation") } catch { }
        await call.stop()
        let requests = await http.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.last!.url!.path.hasSuffix("/rtc_fixture/stop"))
    }

    func testInvalidAnswerStillCleansUpAllocatedCall() async throws {
        let http = ManagedHTTP(answer: "PRIVATE-INVALID-SDP"), call = try await make(http)
        do { _ = try await call.allocate(offer: managedOffer); XCTFail("Invalid answer") }
        catch { XCTAssertEqual(error as? DotManagedVoiceError, .invalidAnswer) }
        await call.stop()
        let requests = await http.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.last!.url!.path.hasSuffix("/stop"))
    }

    func testConflictDoesNotStopAnotherCallOrRetryCreate() async throws {
        let http = ManagedHTTP(createStatus: 409), call = try await make(http)
        do { _ = try await call.allocate(offer: managedOffer); XCTFail("Busy Dot") }
        catch { XCTAssertEqual(error as? DotManagedVoiceError, .busy) }
        await call.stop()
        let requests = await http.snapshot()
        XCTAssertEqual(requests.count, 1)
    }

    func testAccountChangeBlocksAttachAndFurtherAuthenticatedCleanup() async throws {
        let fence = ManagedFence(), http = ManagedHTTP(), call = try await make(http, fence: fence)
        _ = try await call.allocate(offer: managedOffer)
        await fence.change()
        do { try await call.attach(); XCTFail("Changed account") }
        catch { XCTAssertEqual(error as? DotManagedVoiceError, .accountChanged) }
        await call.stop()
        let requests = await http.snapshot()
        XCTAssertEqual(requests.count, 1)
    }

    func testCancellationDuringCreateWaitsForIDThenStopsWithoutAttaching() async throws {
        let http = ManagedHTTP(holdCreate: true), call = try await make(http)
        let allocating = Task { try await call.allocate(offer: managedOffer) }
        await wait { await http.waitingForCreate() }
        allocating.cancel()
        let stopping = Task { await call.stop() }
        await http.finishCreate()
        do { _ = try await allocating.value; XCTFail("Cancelled caller") } catch { }
        await stopping.value
        let requests = await http.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.last!.url!.path.hasSuffix("/stop"))
    }

    func testStopWaitsForAttachBeforeSendingStop() async throws {
        let http = ManagedHTTP(holdAttach: true), call = try await make(http)
        _ = try await call.allocate(offer: managedOffer)
        let attaching = Task { try await call.attach() }
        await wait { await http.waitingForAttach() }
        let stopping = Task { await call.stop() }
        await http.finishAttach()
        _ = try? await attaching.value
        await stopping.value
        let requests = await http.snapshot()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests[1].url!.path.hasSuffix("/attach"))
        XCTAssertTrue(requests[2].url!.path.hasSuffix("/stop"))
    }

    func testDiagnosticPreservesHTTPFailureWithoutPrivateContentAndStopsOwnCall() async throws {
        let sink = ManagedDiagnostics(), http = ManagedHTTP(attachStatus: 403)
        let call = try await make(http, diagnostics: sink)
        _ = try await call.allocate(offer: managedOffer)
        do { try await call.attach(); XCTFail("Attach rejected") }
        catch { XCTAssertEqual(error as? DotManagedVoiceError, .rejected("attach", 403)) }
        await call.stop()
        let values = sink.snapshot()
        XCTAssertEqual(values.last?.failureStage, "attach")
        XCTAssertEqual(values.last?.failureHTTPStatus, 403)
        let encoded = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        for forbidden in ["PRIVATE", "rtc_fixture", "dot-fixture", "root-fixture", "account-fixture", "Bearer", "v=0"] {
            XCTAssertFalse(encoded.contains(forbidden))
        }
    }

    private func wait(_ condition: () async -> Bool) async {
        for _ in 0..<200 { if await condition() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        XCTFail("Timed out waiting for synthetic HTTP")
    }
}
