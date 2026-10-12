import Foundation

// Credentials live in a dotenv file, never in this repo. First readable file
// wins.
enum Config {
    static let searchPaths = [
        "~/.config/capitalbar/env",
        "~/.capitalbar.env",
    ]

    private(set) static var values: [String: String] = [:]
    private(set) static var sourcePath: String?

    static func load() {
        for p in searchPaths {
            let path = NSString(string: p).expandingTildeInPath
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let parsed = parse(text)
            guard parsed["CAPITAL_API_KEY"] != nil else { continue }
            values = parsed
            sourcePath = path
            return
        }
    }

    private static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2, (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }
            out[key] = val
        }
        return out
    }

    // Capital.com issues a separate API key per environment, so a live key may
    // be supplied alongside the demo one rather than replacing it.
    static func creds(for env: TradingEnv) -> Creds? {
        let key: String?
        switch env {
        case .live:  key = values["CAPITAL_LIVE_API_KEY"] ?? values["CAPITAL_API_KEY"]
        case .demo:  key = values["CAPITAL_DEMO_API_KEY"] ?? values["CAPITAL_API_KEY"]
        }
        guard let key, !key.isEmpty,
              let id = values["CAPITAL_IDENTIFIER"], !id.isEmpty,
              let pw = values["CAPITAL_PASSWORD"], !pw.isEmpty else { return nil }
        return Creds(apiKey: key, identifier: id, password: pw)
    }

    static var defaultEnv: TradingEnv {
        (values["CAPITAL_ENVIRONMENT"] ?? "demo").lowercased() == "live" ? .live : .demo
    }
}
