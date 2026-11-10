import CryptoKit
import Foundation

/// Device auth ID and PKCE values remain in memory; only userCode is presented.
struct DeviceAuthorizationChallenge: Sendable {
    let userCode: String
    let interval: TimeInterval
    let expiresAt: Date
    fileprivate let deviceID: String
}

/// Wire flow documented in the official Codex device_code_auth.rs. Uses the
/// existing account client and HTTPS only; no loopback listener or companion.
struct DeviceAuthorizationService: Sendable {
    let http: any SignInHTTP
    static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!

    func begin(now: Date) async throws -> DeviceAuthorizationChallenge {
        let data = try await jsonPost("/api/accounts/deviceauth/usercode", fields: ["client_id": OpenAIOAuthClient.codex])
        struct Response: Decodable {
            let device_auth_id: String
            let code: String
            let interval: TimeInterval
            enum CodingKeys: String, CodingKey { case device_auth_id, user_code, usercode, interval }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                device_auth_id = try c.decode(String.self, forKey: .device_auth_id)
                code = try c.decodeIfPresent(String.self, forKey: .user_code) ?? c.decode(String.self, forKey: .usercode)
                if let text = try? c.decode(String.self, forKey: .interval), let seconds = Double(text) { interval = seconds }
                else { interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? 5 }
            }
        }
        guard let value = try? JSONDecoder().decode(Response.self, from: data),
              !value.device_auth_id.isEmpty, value.device_auth_id.utf8.count <= 4096,
              value.code.range(of: "^[A-Za-z0-9-]{6,64}$", options: .regularExpression) != nil,
              value.interval.isFinite, (1...30).contains(value.interval) else { throw SignInError.invalidResponse }
        try Task.checkCancellation()
        return DeviceAuthorizationChallenge(userCode: value.code, interval: value.interval,
            expiresAt: now.addingTimeInterval(900), deviceID: value.device_auth_id)
    }

    func poll(_ challenge: DeviceAuthorizationChallenge, now: Date) async throws -> SignedInAccount? {
        try Task.checkCancellation()
        guard now < challenge.expiresAt else { throw SignInError.expired }
        let response = try await post("/api/accounts/deviceauth/token", fields: [
            "device_auth_id": challenge.deviceID, "user_code": challenge.userCode])
        try Task.checkCancellation()
        // Official service uses 403/404 while browser authorization is pending.
        if response.status == 403 || response.status == 404 { return nil }
        guard (200..<300).contains(response.status), !response.clientChallenge else { throw SignInError.denied }
        struct Grant: Decodable { let authorization_code: String; let code_challenge: String; let code_verifier: String }
        guard let grant = try? JSONDecoder().decode(Grant.self, from: response.data),
              !grant.authorization_code.isEmpty, grant.authorization_code.utf8.count <= 4096,
              grant.code_verifier.range(of: "^[A-Za-z0-9._~-]{43,128}$", options: .regularExpression) != nil,
              grant.code_challenge == Data(SHA256.hash(data: Data(grant.code_verifier.utf8))).base64URL else {
            throw SignInError.invalidResponse
        }
        let fields = ["grant_type": "authorization_code", "client_id": OpenAIOAuthClient.codex,
            "redirect_uri": "https://auth.openai.com/deviceauth/callback",
            "code": grant.authorization_code, "code_verifier": grant.code_verifier]
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        let tokensResponse: SignInHTTPResponse
        do { tokensResponse = try await http.sendWithMetadata(request) }
        catch { try Task.checkCancellation(); throw SignInError.exchangeUncertain }
        try Task.checkCancellation()
        struct Tokens: Decodable {
            let id_token: String; let access_token: String; let refresh_token: String; let expires_in: Double?
        }
        guard tokensResponse.status == 200, !tokensResponse.clientChallenge,
              let tokens = try? JSONDecoder().decode(Tokens.self, from: tokensResponse.data),
              !tokens.access_token.isEmpty, tokens.access_token.utf8.count <= 64_000,
              !tokens.refresh_token.isEmpty, tokens.refresh_token.utf8.count <= 64_000,
              tokens.expires_in == nil || (tokens.expires_in!.isFinite && tokens.expires_in! > 0) else { throw SignInError.identity }
        let jwks = try await http.sendWithMetadata(URLRequest(url: URL(string: "https://auth.openai.com/.well-known/jwks.json")!))
        guard jwks.status == 200, !jwks.clientChallenge else { throw SignInError.identity }
        let identity = try OpenAIIdentityVerifier.verifyDeviceCode(tokens.id_token, jwks: jwks.data,
            clientID: OpenAIOAuthClient.codex, now: now)
        try Task.checkCancellation()
        let expiration = min(identity.expiresAt, now.addingTimeInterval(tokens.expires_in ?? identity.expiresAt.timeIntervalSince(now)))
        return SignedInAccount(subject: identity.subject, clientID: OpenAIOAuthClient.codex,
            email: identity.email, expiresAt: expiration, idToken: tokens.id_token,
            accessToken: tokens.access_token, refreshToken: tokens.refresh_token)
    }

    private func post(_ path: String, fields: [String: String]) async throws -> SignInHTTPResponse {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://auth.openai.com" + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        return try await http.sendWithMetadata(request)
    }
    private func jsonPost(_ path: String, fields: [String: String]) async throws -> Data {
        let response = try await post(path, fields: fields)
        guard (200..<300).contains(response.status), !response.clientChallenge else { throw SignInError.denied }
        return response.data
    }
}
