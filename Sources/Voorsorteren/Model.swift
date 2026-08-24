import Foundation

/// Praat met elk eindpunt dat de OpenAI-vorm spreekt: Ollama, vLLM, LiteLLM, een clouddienst.
/// Het model krijgt hier bewust GEEN gereedschap aangeboden -- alleen tekst in, tekst uit.
/// Een instructie die in een e-mail verstopt zit kan daardoor hooguit een verkeerd
/// formulier opleveren, geen handeling.
struct ModelClient {
    let eindpunt: String
    let sleutel: String
    let model: String

    enum Fout: LocalizedError {
        case ongeldigAdres(String)
        case geenAntwoord
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .ongeldigAdres(let a): return "Het adres '\(a)' is geen geldige URL."
            case .geenAntwoord: return "Het model gaf een leeg antwoord."
            case .http(let code, let tekst):
                return "Het model antwoordde met code \(code). \(tekst)"
            }
        }
    }

    func vraag(systeem: String, gebruiker: String, maxTokens: Int = 400) async throws -> String {
        let basis = eindpunt.hasSuffix("/") ? String(eindpunt.dropLast()) : eindpunt
        guard let url = URL(string: basis + "/chat/completions") else {
            throw Fout.ongeldigAdres(eindpunt)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !sleutel.isEmpty {
            req.setValue("Bearer \(sleutel)", forHTTPHeaderField: "Authorization")
        }

        let lichaam: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": systeem],
                ["role": "user", "content": gebruiker],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: lichaam)

        let (data, antwoord) = try await URLSession.shared.data(for: req)
        if let h = antwoord as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            let tekst = String(data: data, encoding: .utf8) ?? ""
            throw Fout.http(h.statusCode, String(tekst.prefix(200)))
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let keuzes = root["choices"] as? [[String: Any]],
            let bericht = keuzes.first?["message"] as? [String: Any],
            let inhoud = bericht["content"] as? String,
            !inhoud.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw Fout.geenAntwoord }

        return inhoud
    }

    /// Haalt het JSON-object uit een antwoord dat er ook proza omheen kan hebben gezet.
    static func jsonUit(_ ruw: String) -> [String: Any]? {
        var t = ruw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = t.range(of: "```") {
            t = String(t[start.upperBound...])
            if t.hasPrefix("json") { t = String(t.dropFirst(4)) }
            if let eind = t.range(of: "```") { t = String(t[..<eind.lowerBound]) }
        }
        guard let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a < b else { return nil }
        let blok = String(t[a...b])
        return (try? JSONSerialization.jsonObject(with: Data(blok.utf8))) as? [String: Any]
    }
}
