import Foundation

struct Creds {
    let apiKey: String
    let identifier: String
    let password: String
}

enum TradingEnv: String {
    case demo, live

    var base: String {
        switch self {
        case .demo: return "https://demo-api-capital.backend-capital.com/api/v1"
        case .live: return "https://api-capital.backend-capital.com/api/v1"
        }
    }
    var label: String { self == .live ? "LIVE" : "Demo" }
}

// MARK: - Wire models

struct AccountBalance: Decodable {
    let balance: Double?
    let deposit: Double?
    let profitLoss: Double?
    let available: Double?
}

struct Account: Decodable {
    let accountId: String
    let accountName: String?
    let currency: String?
    let preferred: Bool?
    let balance: AccountBalance?
}

private struct AccountsResponse: Decodable { let accounts: [Account] }

struct PositionDetail: Decodable {
    let dealId: String
    let size: Double
    let direction: String
    let level: Double
    let upl: Double?
    let currency: String?
    let stopLevel: Double?
    let profitLevel: Double?
}

struct MarketDetail: Decodable {
    let instrumentName: String?
    let epic: String
    let bid: Double?
    let offer: Double?
    let marketStatus: String?
}

struct Position: Decodable {
    let position: PositionDetail
    let market: MarketDetail

    var pnl: Double { position.upl ?? 0 }
    var name: String { market.instrumentName ?? market.epic }
}

private struct PositionsResponse: Decodable { let positions: [Position] }

struct MarketSearchResult: Decodable {
    let epic: String
    let instrumentName: String?
    let bid: Double?
    let offer: Double?
    let marketStatus: String?
}

private struct MarketsResponse: Decodable { let markets: [MarketSearchResult] }

struct QuoteInstrument: Decodable {
    let epic: String
    let name: String?
}

struct QuoteSnapshot: Decodable {
    let bid: Double?
    let offer: Double?
    let percentageChange: Double?
    let netChange: Double?
    let high: Double?
    let low: Double?
    let marketStatus: String?
}

struct MarketQuote: Decodable {
    let instrument: QuoteInstrument
    let snapshot: QuoteSnapshot

    var epic: String { instrument.epic }
    var name: String { instrument.name ?? instrument.epic }
    var mid: Double? {
        guard let b = snapshot.bid, let o = snapshot.offer else { return snapshot.offer ?? snapshot.bid }
        return (b + o) / 2
    }
    var isTradeable: Bool { (snapshot.marketStatus ?? "").uppercased() == "TRADEABLE" }
}

private struct MarketDetailsResponse: Decodable { let marketDetails: [MarketQuote] }

struct DealReference: Decodable { let dealReference: String }

struct DealConfirmation: Decodable {
    let dealStatus: String?
    let reason: String?
    let dealId: String?
    let status: String?
    let epic: String?
    let size: Double?
    let level: Double?
}

struct CapitalError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Client

// One session (CST + security token) per environment, re-established lazily on
// 401. Capital.com rate-limits /session to ~1 req/s, so logins are serialized
// by the actor and spaced out; everything else piggybacks the live session.
actor CapitalClient {
    private struct Session {
        var cst: String
        var token: String
        var createdAt: Date
    }

    private var sessions: [TradingEnv: Session] = [:]
    private var lastLoginAt: [TradingEnv: Date] = [:]
    private let http: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    func logout(_ env: TradingEnv) { sessions[env] = nil }

    private func login(_ env: TradingEnv, _ creds: Creds) async throws {
        if let last = lastLoginAt[env] {
            let gap = 2.0 - Date().timeIntervalSince(last)
            if gap > 0 { try await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000)) }
        }
        lastLoginAt[env] = Date()

        var req = URLRequest(url: URL(string: env.base + "/session")!)
        req.httpMethod = "POST"
        req.setValue(creds.apiKey, forHTTPHeaderField: "X-CAP-API-KEY")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": creds.identifier,
            "password": creds.password,
            "encryptedPassword": false,
        ])

        let (data, response) = try await http.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CapitalError(message: "no response") }
        guard http.statusCode == 200 else {
            throw CapitalError(message: "login failed (HTTP \(http.statusCode)) — \(Self.snippet(data))")
        }
        guard let cst = http.value(forHTTPHeaderField: "CST"),
              let token = http.value(forHTTPHeaderField: "X-SECURITY-TOKEN") else {
            throw CapitalError(message: "login returned no session tokens")
        }
        sessions[env] = Session(cst: cst, token: token, createdAt: Date())
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil,
                         env: TradingEnv, creds: Creds) async throws -> Data {
        for attempt in 0..<2 {
            if sessions[env] == nil { try await login(env, creds) }
            guard let session = sessions[env] else { throw CapitalError(message: "no session") }

            var req = URLRequest(url: URL(string: env.base + path)!)
            req.httpMethod = method
            req.setValue(creds.apiKey, forHTTPHeaderField: "X-CAP-API-KEY")
            req.setValue(session.cst, forHTTPHeaderField: "CST")
            req.setValue(session.token, forHTTPHeaderField: "X-SECURITY-TOKEN")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }

            let (data, response) = try await http.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw CapitalError(message: "no response") }
            if http.statusCode == 401 && attempt == 0 {
                sessions[env] = nil // expired, or invalidated by a login elsewhere
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw CapitalError(message: "\(method) \(path) HTTP \(http.statusCode) — \(Self.snippet(data))")
            }
            return data
        }
        throw CapitalError(message: "authentication failed twice")
    }

    private static func snippet(_ data: Data) -> String {
        String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CapitalError(message: "unexpected response: \(Self.snippet(data))") }
    }

    // MARK: reads

    func accounts(env: TradingEnv, creds: Creds) async throws -> [Account] {
        try decode(AccountsResponse.self, try await request("GET", "/accounts", env: env, creds: creds)).accounts
    }

    func positions(env: TradingEnv, creds: Creds) async throws -> [Position] {
        try decode(PositionsResponse.self, try await request("GET", "/positions", env: env, creds: creds)).positions
    }

    func search(_ term: String, env: TradingEnv, creds: Creds) async throws -> [MarketSearchResult] {
        let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        return try decode(MarketsResponse.self, try await request("GET", "/markets?searchTerm=" + q, env: env, creds: creds)).markets
    }

    // One call covers every favourite; Capital caps the batch at 50 epics.
    func quotes(epics: [String], env: TradingEnv, creds: Creds) async throws -> [MarketQuote] {
        guard !epics.isEmpty else { return [] }
        let list = epics.prefix(50).joined(separator: ",")
        let q = list.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? list
        return try decode(MarketDetailsResponse.self,
                          try await request("GET", "/markets?epics=" + q, env: env, creds: creds)).marketDetails
    }

    // MARK: dealing — only ever called from an explicit user click

    func openPosition(epic: String, direction: String, size: Double,
                      stopLevel: Double?, profitLevel: Double?,
                      env: TradingEnv, creds: Creds) async throws -> DealConfirmation {
        var body: [String: Any] = [
            "epic": epic,
            "direction": direction.uppercased(),
            "size": size,
            "guaranteedStop": false,
        ]
        if let stopLevel { body["stopLevel"] = stopLevel }
        if let profitLevel { body["profitLevel"] = profitLevel }
        let ref = try decode(DealReference.self, try await request("POST", "/positions", body: body, env: env, creds: creds))
        return try await confirm(ref.dealReference, env: env, creds: creds)
    }

    func closePosition(dealId: String, env: TradingEnv, creds: Creds) async throws -> DealConfirmation {
        let path = "/positions/" + (dealId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dealId)
        let ref = try decode(DealReference.self, try await request("DELETE", path, env: env, creds: creds))
        return try await confirm(ref.dealReference, env: env, creds: creds)
    }

    // Dealing is async on Capital's side: the POST/DELETE returns a reference,
    // and the outcome only shows up on /confirms a moment later.
    private func confirm(_ reference: String, env: TradingEnv, creds: Creds) async throws -> DealConfirmation {
        let path = "/confirms/" + (reference.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? reference)
        var lastError: Error?
        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 400_000_000)
            do { return try decode(DealConfirmation.self, try await request("GET", path, env: env, creds: creds)) }
            catch { lastError = error }
        }
        throw lastError ?? CapitalError(message: "deal \(reference): no confirmation")
    }
}
