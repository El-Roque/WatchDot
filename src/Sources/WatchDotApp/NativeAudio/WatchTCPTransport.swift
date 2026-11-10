import Darwin
import Foundation
import Network
import OpenClawWatchRTC

/// Direct ICE-TCP. The OS selects the interface/proxy; no companion channel,
/// interface enumeration, pre-bound local address, TLS wrapper or UDP fallback.
final class WatchTCPTransport: @unchecked Sendable {
    private struct Flow {
        let connection: NWConnection
        let remote: NWEndpoint
        let candidateIndex: Int
        var local: NWEndpoint?
        var actualRemote: NWEndpoint?
        var framing = VoiceTCPFraming()
        var pending: [Data] = []
        var queuedBytes = 0
        var writing = false
    }
    private let queue = DispatchQueue(label: "ar.rochi.watchdot.tcp", qos: .userInitiated)
    private let cancellation = NSLock()
    private var cancelled = false
    private var terminal = false
    private var rtc: OpaquePointer?
    private var flows: [UUID: Flow] = [:]
    private var activeFlow: UUID?
    private var timer: DispatchSourceTimer?
    private var answerWaiter: CheckedContinuation<Void, Error>?
    private let onEvent: @Sendable (WatchRealtimeMediaEvent) -> Void
    private var sent = 0
    private var received = 0
    private var connected = false
    private var eventsOpen = false
    private var lastDiagnostic = ContinuousClock.now
    // Retain only categorical facts after failed flows are removed. Never retain
    // endpoint descriptions, IP addresses, ports, SDP or ICE credentials.
    private var routeObservations: [[String: Any]] = []
    private var unmatchedPacketRoute: [String: Any]?
    private var skippedChecksWithoutSocket = 0

    init(onEvent: @escaping @Sendable (WatchRealtimeMediaEvent) -> Void) { self.onEvent = onEvent }

    deinit {
        timer?.cancel()
        flows.values.forEach { $0.connection.cancel() }
        if let rtc { openclaw_rtc_free(rtc) }
    }

    func makeOffer() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try self.checkLive()
                        guard self.rtc == nil, let rtc = watchdot_rtc_create_tcp() else {
                            throw WatchRealtimeMediaError.unavailable("Could not prepare the TCP engine.")
                        }
                        self.rtc = rtc
                        try self.mutate { openclaw_rtc_offer($0) }
                        var count = 0
                        guard let bytes = openclaw_rtc_description(rtc, &count), count > 0,
                              let sdp = String(data: Data(bytes: bytes, count: count), encoding: .utf8) else {
                            throw WatchRealtimeMediaError.unavailable("Could not prepare the TCP offer.")
                        }
                        continuation.resume(returning: sdp)
                    } catch { continuation.resume(throwing: error); self.fail(code: -601) }
                }
            }
        } onCancel: { self.cancel() }
    }

    func applyAnswer(_ answer: String) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        try self.checkLive()
                        guard self.answerWaiter == nil, self.flows.isEmpty else { throw CancellationError() }
                        let data = Data(answer.utf8)
                        try data.withUnsafeBytes { bytes in
                            try self.mutate { openclaw_rtc_answer($0, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count) }
                        }
                        guard let rtc = self.rtc else { throw CancellationError() }
                        var endpoints: [(index: Int, endpoint: NWEndpoint)] = []
                        for index in 0...100 {
                            var value = OpenClawRTCAddress()
                            let result = openclaw_rtc_remote_address(rtc, index, &value)
                            if result == 1 { break }
                            guard result == 0, index < 100 else {
                                throw WatchRealtimeMediaError.unavailable("Dot did not provide a usable TCP route.")
                            }
                            let endpoint = try Self.endpoint(value)
                            if !endpoints.contains(where: { $0.endpoint == endpoint }) {
                                endpoints.append((index, endpoint))
                            }
                        }
                        guard !endpoints.isEmpty else {
                            throw WatchRealtimeMediaError.unavailable("Dot did not provide passive TCP candidates.")
                        }
                        self.answerWaiter = continuation
                        for item in endpoints { self.open(item.endpoint, candidateIndex: item.index) }
                        self.record("connecting")
                    } catch {
                        continuation.resume(throwing: error)
                        self.fail(code: -602)
                    }
                }
            }
        } onCancel: { self.cancel() }
    }

    func sendOpus(_ data: Data, timestamp: UInt64) {
        queue.async {
            guard self.rtc != nil, !self.terminal else { return }
            do {
                try data.withUnsafeBytes { bytes in
                    try self.mutate { openclaw_rtc_send_opus($0, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, timestamp) }
                }
            } catch { self.fail(code: -603) }
        }
    }

    func sendEvent(_ text: String) async throws {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= 65_536 else { throw WatchRealtimeEventSendError.invalidText }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.checkLive()
                    guard let rtc = self.rtc else { throw CancellationError() }
                    let result = data.withUnsafeBytes {
                        watchdot_rtc_send_event(rtc, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), $0.count)
                    }
                    try self.drain()
                    switch result {
                    case 0: continuation.resume()
                    case -5: throw WatchRealtimeEventSendError.notOpen
                    case -6: throw WatchRealtimeEventSendError.backpressure
                    default: throw WatchRealtimeEventSendError.invalidText
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func open(_ endpoint: NWEndpoint, candidateIndex: Int) {
        let parameters = NWParameters.tcp
        parameters.serviceClass = .interactiveVoice
        let connection = NWConnection(to: endpoint, using: parameters)
        let id = UUID()
        flows[id] = Flow(connection: connection, remote: endpoint, candidateIndex: candidateIndex)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                guard self.flows[id] != nil, !self.terminal else { return }
                switch state {
                case .ready: self.ready(id)
                case .failed(let error): self.flowFailed(id, code: Self.code(error))
                default: break
                }
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 18) { [weak self] in
            guard let self, let flow = self.flows[id], flow.local == nil else { return }
            self.flowFailed(id, code: -604)
        }
    }

    private func ready(_ id: UUID) {
        guard var flow = flows[id], flow.local == nil else { return }
        let path = flow.connection.currentPath
        let local = path?.localEndpoint
        let remote = path?.remoteEndpoint
        var facts: [String: Any] = [
            "localFamily": Self.family(local), "remoteFamily": Self.family(remote),
            "requestedFamily": Self.family(flow.remote),
            "hasLocalEndpoint": local != nil, "hasRemoteEndpoint": remote != nil,
            "remoteMatchesRequested": remote == flow.remote,
            "usesWiFi": path?.usesInterfaceType(.wifi) ?? false,
            "usesCellular": path?.usesInterfaceType(.cellular) ?? false,
            "usesOther": path?.usesInterfaceType(.other) ?? false
        ]
        var failureCode = -611
        do {
            guard let local, let remote else { throw CancellationError() }
            // Keep the observed socket tuple. The system may proxy a requested
            // IPv4 peer through IPv6 and another port. Associate that real peer
            // with its original candidate; never invent a local IPv4 address.
            failureCode = -612
            let localAddress = try Self.native(local)
            failureCode = -613
            let remoteAddress = try Self.native(remote)
            facts["localRoundTripMatches"] = (try? Self.endpoint(localAddress)) == local
            facts["remoteRoundTripMatches"] = (try? Self.endpoint(remoteAddress)) == remote
            if let requested = try? Self.native(flow.remote) {
                facts["remoteNativeMatchesRequested"] = Self.sameAddress(remoteAddress, requested)
                facts["remotePortMatchesRequested"] = remoteAddress.port == requested.port
            }
            facts["localPortIsZero"] = localAddress.port == 0
            facts["remotePortIsZero"] = remoteAddress.port == 0
            facts["localAddressIsUnspecified"] = Self.isUnspecified(localAddress)
            failureCode = -614
            guard localAddress.family == remoteAddress.family else {
                throw WatchRealtimeMediaError.unavailable("The TCP route changed while connecting.")
            }
            flow.local = local
            flow.actualRemote = remote
            flows[id] = flow
            failureCode = -618
            try mutate {
                let result = openclaw_rtc_resolve_remote_address($0, flow.candidateIndex, remoteAddress)
                facts["nativeRouteResult"] = result
                return result
            }
            failureCode = -616
            try mutate {
                let result = openclaw_rtc_add_candidate($0, localAddress)
                facts["nativeCandidateResult"] = result
                return result
            }
            facts["resultCode"] = 0
            rememberRoute(facts)
            let pending = answerWaiter; answerWaiter = nil
            pending?.resume()
            receive(id)
            record("socketReady")
        } catch {
            facts["resultCode"] = failureCode
            rememberRoute(facts)
            flowFailed(id, code: failureCode)
        }
    }

    private func rememberRoute(_ facts: [String: Any]) {
        if routeObservations.count < 100 { routeObservations.append(facts) }
    }

    private func receive(_ id: UUID) {
        guard let flow = flows[id], !terminal else { return }
        flow.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                guard var flow = self.flows[id], !self.terminal else { return }
                do {
                    if let data, !data.isEmpty {
                        let packets = try flow.framing.append(data)
                        self.flows[id] = flow
                        guard let source = flow.actualRemote, let destination = flow.local else { throw CancellationError() }
                        let from = try Self.native(source), to = try Self.native(destination)
                        for packet in packets {
                            self.received += 1
                            if !Self.isCheck(packet) { self.activeFlow = id }
                            try packet.withUnsafeBytes { bytes in
                                try self.mutate { openclaw_rtc_receive($0, from, to, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count) }
                            }
                        }
                    }
                    if let error { self.flowFailed(id, code: Self.code(error)); return }
                    if complete { self.flowFailed(id, code: -606); return }
                    self.receive(id)
                    if self.lastDiagnostic.duration(to: .now) > .seconds(2) { self.record("active") }
                } catch { self.flowFailed(id, code: -607) }
            }
        }
    }

    private func enqueue(_ packet: Data, source: NWEndpoint, destination: NWEndpoint) throws {
        guard let id = flows.first(where: { $0.value.local == source && $0.value.actualRemote == destination })?.key,
              var flow = flows[id] else {
            let sourceAddress = try? Self.native(source), destinationAddress = try? Self.native(destination)
            unmatchedPacketRoute = [
                "sourceFamily": Self.family(source), "destinationFamily": Self.family(destination),
                "sourceEndpointMatches": flows.values.filter { $0.local == source }.count,
                "destinationEndpointMatches": flows.values.filter { $0.actualRemote == destination }.count,
                "nativeTupleMatches": flows.values.filter { flow in
                    guard let local = flow.local, let remote = flow.actualRemote,
                          let from = try? Self.native(local), let to = try? Self.native(remote),
                          let sourceAddress, let destinationAddress else { return false }
                    return Self.sameAddress(from, sourceAddress) && Self.sameAddress(to, destinationAddress)
                }.count
            ]
            // ICE may check the cross-product of candidates, but a TCP socket
            // owns exactly one observed tuple. An unavailable check behaves as
            // packet loss; never send it through a different socket or tear
            // down other viable pairs. Media still requires an exact owner.
            if Self.isCheck(packet) {
                skippedChecksWithoutSocket += 1
                return
            }
            throw CancellationError()
        }
        let framed = try VoiceTCPFraming.frame(packet)
        guard flow.queuedBytes + framed.count <= 32_768,
              flows.values.reduce(0, { $0 + $1.queuedBytes }) + framed.count <= 65_536 else {
            throw WatchRealtimeEventSendError.backpressure
        }
        if !Self.isCheck(packet) { activeFlow = id }
        flow.pending.append(framed)
        flow.queuedBytes += framed.count
        flows[id] = flow
        writeNext(id)
    }

    private func writeNext(_ id: UUID) {
        guard var flow = flows[id], !flow.writing, !flow.pending.isEmpty, !terminal else { return }
        let bytes = flow.pending.removeFirst()
        flow.writing = true
        flows[id] = flow
        flow.connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard var flow = self.flows[id], !self.terminal else { return }
                flow.queuedBytes -= bytes.count
                flow.writing = false
                self.flows[id] = flow
                if let error { self.flowFailed(id, code: Self.code(error)); return }
                self.sent += 1
                self.writeNext(id)
            }
        })
    }

    private func mutate(_ body: (OpaquePointer) -> Int32) throws {
        try checkLive()
        guard let rtc, body(rtc) == 0 else { throw WatchRealtimeMediaError.unavailable("The TCP engine failed.") }
        try drain()
    }

    private func drain() throws {
        try checkLive()
        guard let rtc else { throw CancellationError() }
        while true {
            var value = OpenClawRTCOutput()
            guard openclaw_rtc_poll(rtc, &value) == 0 else {
                throw WatchRealtimeMediaError.unavailable("The TCP engine failed.")
            }
            let data = value.length > 0 && value.bytes != nil ? Data(bytes: value.bytes!, count: value.length) : Data()
            switch value.kind {
            case 0: armTimer(milliseconds: value.time); return
            case 10: try enqueue(data, source: Self.endpoint(value.source), destination: Self.endpoint(value.destination))
            case 1: throw WatchRealtimeMediaError.unavailable("TCP mode received a UDP route.")
            case 2: connected = true; onEvent(.connected); record("connected")
            case 3: onEvent(.audio(data, timestamp: value.time))
            case 6: eventsOpen = true; onEvent(.eventsOpen)
            case 7: onEvent(.event(data))
            case 8: onEvent(.eventsClosed)
            case 4, 5, 9: throw WatchRealtimeMediaError.unavailable("The TCP transport closed.")
            default: break
            }
        }
    }

    private func armTimer(milliseconds: UInt64) {
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in
                guard let self, !self.terminal else { return }
                do { try self.mutate { openclaw_rtc_timeout($0) } }
                catch { self.fail(code: -608) }
            }
            self.timer = timer
            timer.resume()
        }
        timer?.schedule(deadline: .now() + .milliseconds(Int(max(1, min(milliseconds, 60_000)))))
    }

    private func flowFailed(_ id: UUID, code: Int) {
        guard let flow = flows.removeValue(forKey: id) else { return }
        flow.connection.cancel()
        if activeFlow == id || flows.isEmpty { fail(code: code); return }
        if let local = flow.local {
            do {
                let address = try Self.native(local)
                try mutate { openclaw_rtc_remove_candidate($0, address) }
            } catch { fail(code: -610) }
        }
    }

    private func checkLive() throws {
        guard !terminal, !cancellation.withLock({ cancelled }) else { throw CancellationError() }
    }

    private func fail(code: Int) {
        guard !terminal else { return }
        record("failed", code: code)
        finish()
        onEvent(.ended(WatchRealtimeMediaFailure(kind: .network,
            message: "The TCP connection was interrupted [\(code)].", reason: .socketFailed, systemCode: code)))
    }

    private func finish() {
        guard !terminal else { return }
        terminal = true
        cancellation.withLock { cancelled = true }
        timer?.cancel(); timer = nil
        flows.values.forEach { $0.connection.cancel() }; flows.removeAll()
        if let rtc { openclaw_rtc_free(rtc); self.rtc = nil }
        let pending = answerWaiter; answerWaiter = nil
        pending?.resume(throwing: CancellationError())
    }

    func cancel() {
        cancellation.withLock { cancelled = true }
        queue.async { self.finish() }
    }

    func stop() async {
        cancel()
        await withCheckedContinuation { continuation in
            queue.async { self.finish(); continuation.resume() }
        }
    }

    private func record(_ stage: String, code: Int? = nil) {
        lastDiagnostic = .now
        let paths = flows.values.compactMap { $0.connection.currentPath }
        var fields: [String: Any] = ["revision": "independent-tcp-3", "stage": stage,
            "recordedAt": Date().timeIntervalSince1970, "sentPackets": sent, "receivedPackets": received,
            "connected": connected, "eventsOpen": eventsOpen,
            "readySockets": flows.values.filter { $0.local != nil }.count,
            "usesWiFi": paths.contains { $0.usesInterfaceType(.wifi) },
            "usesCellular": paths.contains { $0.usesInterfaceType(.cellular) },
            "usesOther": paths.contains { $0.usesInterfaceType(.other) },
            "skippedChecksWithoutSocket": skippedChecksWithoutSocket,
            "routeObservations": routeObservations]
        if let code { fields["systemCode"] = code }
        if let unmatchedPacketRoute { fields["unmatchedPacketRoute"] = unmatchedPacketRoute }
        if let data = try? JSONSerialization.data(withJSONObject: fields) {
            VoiceDiagnosticStore.shared.submit(data, to: URL.cachesDirectory.appendingPathComponent("watchdot-tcp-diagnostic.json"))
        }
    }

    private static func isCheck(_ data: Data) -> Bool {
        data.count >= 20 && data[0] & 0xc0 == 0 && data[4..<8].elementsEqual([0x21, 0x12, 0xa4, 0x42])
    }
    private static func code(_ error: NWError) -> Int {
        if case .posix(let code) = error { return Int(code.rawValue) }
        return -609
    }
    private static func family(_ endpoint: NWEndpoint?) -> Int {
        guard let endpoint, case .hostPort(let host, _) = endpoint else { return 0 }
        switch host {
        case .ipv4: return 4
        case .ipv6: return 6
        case .name: return 1
        @unknown default: return 0
        }
    }
    private static func sameAddress(_ left: OpenClawRTCAddress, _ right: OpenClawRTCAddress) -> Bool {
        guard left.family == right.family, left.port == right.port else { return false }
        var left = left, right = right
        return withUnsafeBytes(of: &left.address) { Data($0) } == withUnsafeBytes(of: &right.address) { Data($0) }
    }
    private static func isUnspecified(_ address: OpenClawRTCAddress) -> Bool {
        var address = address
        return withUnsafeBytes(of: &address.address) { $0.allSatisfy { $0 == 0 } }
    }
    private static func native(_ endpoint: NWEndpoint) throws -> OpenClawRTCAddress {
        guard case .hostPort(let host, let port) = endpoint, port.rawValue != 0 else { throw CancellationError() }
        var value = OpenClawRTCAddress(), bytes: Data
        switch host {
        case .ipv4(let ip): value.family = 4; bytes = ip.rawValue
        case .ipv6(let ip): value.family = 6; bytes = ip.rawValue
        default: throw CancellationError()
        }
        value.port = port.rawValue
        withUnsafeMutableBytes(of: &value.address) { $0.copyBytes(from: bytes) }
        return value
    }
    private static func endpoint(_ input: OpenClawRTCAddress) throws -> NWEndpoint {
        var input = input
        let bytes = withUnsafeBytes(of: &input.address) { Data($0.prefix(input.family == 4 ? 4 : 16)) }
        guard let port = NWEndpoint.Port(rawValue: input.port) else { throw CancellationError() }
        if input.family == 4, let ip = IPv4Address(bytes) { return .hostPort(host: .ipv4(ip), port: port) }
        if input.family == 6, let ip = IPv6Address(bytes) { return .hostPort(host: .ipv6(ip), port: port) }
        throw CancellationError()
    }
}
