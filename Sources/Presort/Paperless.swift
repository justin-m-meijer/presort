import Foundation

/// Uploads documents to a paperless-ngx of your own.
///
/// The point is not that the app can POST a file -- it is what it can say about the file.
/// Paperless works out a document's title, sender and date by reading the scan; Presort had
/// the envelope in its hands. Sending the sender and the date along turns a minute of model
/// time into a field that was already known.
///
/// Written against paperless-ngx 3.x: `POST /api/documents/post_document/`, file field
/// `document`, `Authorization: Token …`, no CSRF. The upload is queued, so what comes back
/// is a task id and not a document -- see `outcome(ofTask:)`.
actor Paperless {
    struct Config: Equatable {
        var address: String = ""
        var token: String = ""
        /// Applied to everything this app uploads, so you can find them back -- and so a
        /// rule elsewhere can pick them up.
        var tagNames: [String] = []
        /// Off by default: inventing correspondents in somebody's archive is the kind of
        /// mess that takes an afternoon to undo.
        var createCorrespondent = false
    }

    private var config: Config
    init(config: Config) { self.config = config }
    func setConfig(_ c: Config) { config = c }

    enum Problem: LocalizedError {
        case notConfigured
        case badAddress(String)
        case http(Int, String)
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return t("paperless.error.notConfigured")
            case .badAddress(let a): return String(format: t("model.error.badAddress"), a)
            case .http(let code, let body):
                return String(format: t("paperless.error.http"), code, body)
            case .rejected(let why): return String(format: t("paperless.error.rejected"), why)
            }
        }
    }

    // MARK: talking to it

    private func url(_ path: String, _ query: String = "") throws -> URL {
        let base = config.address.hasSuffix("/")
            ? String(config.address.dropLast()) : config.address
        guard !base.isEmpty, let u = URL(string: base + path + query) else {
            throw Problem.badAddress(config.address)
        }
        return u
    }

    private func request(_ u: URL, method: String = "GET") throws -> URLRequest {
        guard !config.token.isEmpty else { throw Problem.notConfigured }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.timeoutInterval = 60
        r.setValue("Token \(config.token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let (data, answer) = try await URLSession.shared.data(for: r)
        if let h = answer as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Problem.http(h.statusCode, String(body.prefix(200)))
        }
        return data
    }

    /// One page of a list endpoint, flattened to id and name. Paperless pages at 25 by
    /// default and this app wants the lot, hence the explicit size.
    private func named(_ path: String) async throws -> [(id: Int, name: String)] {
        let data = try await send(try request(try url(path, "?page_size=1000")))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { row in
            guard let id = row["id"] as? Int, let name = row["name"] as? String else { return nil }
            return (id, name)
        }
    }

    /// Reachable, and does the token work? Reported back verbatim, because "it does not
    /// work" is useless next to a server that is perfectly willing to say why.
    func check() async throws -> String {
        let data = try await send(try request(try url("/api/documents/", "?page_size=1")))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let count = root?["count"] as? Int ?? 0
        let tags = try await named("/api/tags/").count
        return String(format: t("paperless.check.ok"), count, tags)
    }

    func tags() async throws -> [(id: Int, name: String)] { try await named("/api/tags/") }

    // MARK: uploading

    struct Meta {
        var title: String
        var created: Date?
        var correspondent: String
        var tagNames: [String]
    }

    /// Turns names into the ids paperless wants. Matching is case-insensitive on the whole
    /// name: close enough is not good enough when the result is a tag nobody uses again.
    private func ids(forTags wanted: [String], among existing: [(id: Int, name: String)]) -> [Int] {
        wanted.compactMap { want in
            existing.first { $0.name.compare(want, options: .caseInsensitive) == .orderedSame }?.id
        }
    }

    private func correspondentId(_ name: String) async throws -> Int? {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        let existing = try await named("/api/correspondents/")
        if let hit = existing.first(where: {
            $0.name.compare(clean, options: .caseInsensitive) == .orderedSame
        }) { return hit.id }

        guard config.createCorrespondent else { return nil }
        var r = try request(try url("/api/correspondents/"), method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["name": clean])
        let data = try await send(r)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? Int
    }

    /// Hands the file over. What comes back is the id of a queued task, not a document:
    /// paperless consumes in the background, and whether it turned out to be a duplicate is
    /// only known later.
    func upload(_ file: Data, filename: String, meta: Meta) async throws -> String {
        let allTags = try await tags()
        let tagIds = ids(forTags: meta.tagNames + config.tagNames, among: allTags)
        let correspondent = try await correspondentId(meta.correspondent)

        var fields: [(String, String)] = []
        if !meta.title.isEmpty { fields.append(("title", String(meta.title.prefix(120)))) }
        if let d = meta.created { fields.append(("created", Dates.isoDay(d))) }
        if let c = correspondent { fields.append(("correspondent", String(c))) }
        // Repeated rather than comma-joined: that is how the serializer reads a list.
        for id in Set(tagIds) { fields.append(("tags", String(id))) }

        let boundary = "presort-" + UUID().uuidString
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"document\"; filename=\"\(safe(filename))\"\r\n")
        body.append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(file)
        body.append("\r\n--\(boundary)--\r\n")

        var r = try request(try url("/api/documents/post_document/"), method: "POST")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = body

        let data = try await send(r)
        // The answer is a bare JSON string with the task id in it.
        if let s = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
            return s
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\n ")) ?? ""
    }

    enum Outcome {
        case working
        case done(documentId: Int?)
        case failed(String)
    }

    /// Whether the queued upload came to anything. A duplicate lands here as a failure with
    /// paperless's own wording, which is the honest thing to show: nothing was added.
    func outcome(ofTask id: String) async throws -> Outcome {
        guard !id.isEmpty else { return .failed("") }
        let data = try await send(try request(try url("/api/tasks/", "?task_id=\(id)")))
        let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            ?? ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])??["results"]
                as? [[String: Any]]) ?? []
        guard let row = rows.first else { return .working }
        switch (row["status"] as? String ?? "").uppercased() {
        case "SUCCESS":
            return .done(documentId: row["related_document"] as? Int)
        case "FAILURE":
            return .failed(String((row["result"] as? String ?? "").prefix(200)))
        default:
            return .working
        }
    }

    /// A filename the server has no reason to argue with, and that a sender cannot use to
    /// say anything about paths.
    private func safe(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "[^A-Za-z0-9._ -]", with: "_",
                                                options: .regularExpression)
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "._ -"))
        return trimmed.isEmpty ? "document.pdf" : String(trimmed.suffix(120))
    }
}

private extension Data {
    mutating func append(_ s: String) { append(Data(s.utf8)) }
}
