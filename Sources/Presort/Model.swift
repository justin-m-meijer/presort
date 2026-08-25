import Foundation

/// Talks to any endpoint that speaks the OpenAI shape: Ollama, vLLM, LiteLLM, a hosted service.
/// The model is deliberately offered NO tools here -- text in, text out. An instruction hidden
/// inside an email can therefore produce a wrong form at worst, never an action.
struct ModelClient {
    let endpoint: String
    let key: String
    let model: String

    enum Problem: LocalizedError {
        case badAddress(String)
        case emptyAnswer
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .badAddress(let a):
                return String(format: t("model.error.badAddress"), a)
            case .emptyAnswer: return t("model.error.empty")
            case .http(let code, let text):
                return String(format: t("model.error.http"), code, text)
            }
        }
    }

    /// Asks the endpoint which models it serves. Ollama, vLLM, LiteLLM and OpenAI itself all
    /// answer this; plenty of other things do not. A failure here is therefore a reason to
    /// type the name by hand, not an error worth stopping for -- which is why the caller
    /// treats an empty list as "type it yourself" rather than as a broken endpoint.
    func availableModels() async throws -> [String] {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: base + "/models") else {
            throw Problem.badAddress(endpoint)
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let (data, answer) = try await URLSession.shared.data(for: req)
        if let h = answer as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw Problem.http(h.statusCode, String(text.prefix(200)))
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = root["data"] as? [[String: Any]]
        else { return [] }

        let ids = list.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
        return Array(Set(ids)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func ask(system: String, user: String, maxTokens: Int = 400) async throws -> String {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: base + "/chat/completions") else {
            throw Problem.badAddress(endpoint)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let bodyText: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: bodyText)

        let (data, answer) = try await URLSession.shared.data(for: req)
        if let h = answer as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw Problem.http(h.statusCode, String(text.prefix(200)))
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw Problem.emptyAnswer }

        return content
    }

    /// Pulls the JSON object out of an answer that may have wrapped prose around it.
    static func jsonFrom(_ raw: String) -> [String: Any]? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = t.range(of: "```") {
            t = String(t[start.upperBound...])
            if t.hasPrefix("json") { t = String(t.dropFirst(4)) }
            if let end = t.range(of: "```") { t = String(t[..<end.lowerBound]) }
        }
        guard let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a < b else { return nil }
        let block = String(t[a...b])
        return (try? JSONSerialization.jsonObject(with: Data(block.utf8))) as? [String: Any]
    }
}
