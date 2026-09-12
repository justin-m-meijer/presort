import Foundation

/// Talks to any endpoint that speaks the OpenAI shape: Ollama, vLLM, LiteLLM, a hosted service.
/// The model is deliberately offered NO tools here -- text in, text out. An instruction hidden
/// inside an email can therefore produce a wrong form at worst, never an action.
struct ModelClient {
    let endpoint: String
    let key: String
    let model: String
    /// Asks the server to skip a thinking step. Only set for a model the check found needs it:
    /// not every server knows the field, and one that does not may refuse the whole request.
    var thinkingOff = false

    enum Problem: LocalizedError {
        case badAddress(String)
        case emptyAnswer
        case ranOutThinking
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .badAddress(let a):
                return String(format: t("model.error.badAddress"), a)
            case .emptyAnswer: return t("model.error.empty")
            case .ranOutThinking: return t("model.error.ranOut")
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

    /// What came back, including why it stopped. An empty answer on its own says nothing; an
    /// empty answer that stopped at the token limit with reasoning beside it says the model
    /// thought until there was no room left to answer.
    private struct Reply {
        let content: String
        let finish: String
        let reasoning: Int
    }

    private func complete(system: String, user: String, maxTokens: Int,
                          thinkingOff: Bool) async throws -> Reply {
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

        var bodyText: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if thinkingOff {
            // What llama.cpp and vLLM read for Qwen-style models, and what LiteLLM passes on.
            bodyText["chat_template_kwargs"] = ["enable_thinking": false]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: bodyText)

        let (data, answer) = try await URLSession.shared.data(for: req)
        if let h = answer as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw Problem.http(h.statusCode, String(text.prefix(200)))
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else { throw Problem.emptyAnswer }

        let reasoning = (message["reasoning_content"] as? String ?? message["reasoning"] as? String ?? "").count
        return Reply(content: message["content"] as? String ?? "",
                     finish: first["finish_reason"] as? String ?? "",
                     reasoning: reasoning)
    }

    func ask(system: String, user: String, maxTokens: Int = 400) async throws -> String {
        let reply = try await complete(system: system, user: user, maxTokens: maxTokens,
                                       thinkingOff: thinkingOff)
        guard !reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelClient.read(reply.content, finish: reply.finish, reasoning: reply.reasoning)
                == .ranOutThinking ? Problem.ranOutThinking : Problem.emptyAnswer
        }
        return reply.content
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

// MARK: checking a model

extension ModelClient {
    /// Whether a model is any use to this app, and if not, why.
    enum Health: Equatable, Sendable {
        case works
        /// Answers well once asked to skip its thinking step.
        case needsThinkingOff
        /// Thinks until there is no room left to answer, also when asked not to.
        case thinksTooLong
        /// Answers, but not with the JSON the app reads. Carries the start of what it said.
        case noForm(String)
        /// Right form, wrong answer to a question with an obvious one.
        case wrong
        case unreachable(String)
    }

    struct Check: Sendable {
        let health: Health
        let seconds: Double

        var usable: Bool { health == .works || health == .needsThinkingOff }

        var sentence: String {
            switch health {
            case .works: return String(format: t("modelcheck.works"), seconds)
            case .needsThinkingOff: return String(format: t("modelcheck.worksWithoutThinking"), seconds)
            case .thinksTooLong: return t("modelcheck.thinksTooLong")
            case .noForm(let said): return String(format: t("modelcheck.noForm"), said)
            case .wrong: return t("modelcheck.wrong")
            case .unreachable(let why): return String(format: t("modelcheck.unreachable"), why)
            }
        }
    }

    /// What one answer to the probe says. Kept apart from the request, so it can be tested
    /// without a server.
    enum ProbeReading: Equatable {
        case answered
        case ranOutThinking
        case noForm(String)
        case wrong
    }

    static func read(_ content: String, finish: String, reasoning: Int) -> ProbeReading {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && (finish == "length" || reasoning > 0) { return .ranOutThinking }
        guard let o = jsonFrom(text) else { return .noForm(String(text.prefix(80))) }
        let begin = o["begin"] as? String ?? ""
        return o["gevonden"] as? Bool == true && begin.contains("-10-14T10:30") ? .answered : .wrong
    }

    /// The question the check asks: the built-in appointment point -- never the user's own
    /// wording -- about a made-up confirmation, in the app's language and in the same frame
    /// a real message gets. No mail of anybody's goes into it.
    static func probe() -> (system: String, user: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let user = """
        \(String(format: t("frame.today"), f.string(from: Date())))
        \(t("frame.sender")) Smile Dental <info@example.com>
        \(t("frame.subject")) \(t("probe.subject"))

        \(t("frame.untrusted"))
        \(t("probe.body"))
        \(t("frame.end"))
        """
        return (Detector.builtIn.first { $0.id == "afspraak" }?.systemText ?? "", user)
    }

    /// Puts the probe to this model with the same token budget as the real work, which is
    /// exactly where a thinking model runs out. When it does, the question is asked once more
    /// with thinking switched off, so the answer can be "works like that" instead of "broken".
    func check(startingWith thinkingOff: Bool = false) async -> Check {
        let started = Date()
        let (system, user) = ModelClient.probe()
        do {
            let first = try await complete(system: system, user: user, maxTokens: 400,
                                           thinkingOff: thinkingOff)
            switch ModelClient.read(first.content, finish: first.finish, reasoning: first.reasoning) {
            case .answered:
                return Check(health: thinkingOff ? .needsThinkingOff : .works,
                             seconds: Date().timeIntervalSince(started))
            case .noForm(let said):
                return Check(health: .noForm(said), seconds: Date().timeIntervalSince(started))
            case .wrong:
                return Check(health: .wrong, seconds: Date().timeIntervalSince(started))
            case .ranOutThinking:
                guard !thinkingOff else {
                    return Check(health: .thinksTooLong, seconds: Date().timeIntervalSince(started))
                }
                let again = Date()
                if let quiet = try? await complete(system: system, user: user, maxTokens: 400,
                                                   thinkingOff: true),
                   ModelClient.read(quiet.content, finish: quiet.finish, reasoning: quiet.reasoning) == .answered {
                    return Check(health: .needsThinkingOff, seconds: Date().timeIntervalSince(again))
                }
                return Check(health: .thinksTooLong, seconds: Date().timeIntervalSince(started))
            }
        } catch {
            return Check(health: .unreachable(error.localizedDescription),
                         seconds: Date().timeIntervalSince(started))
        }
    }
}
