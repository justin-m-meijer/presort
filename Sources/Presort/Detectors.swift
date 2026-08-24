import AppKit
import Foundation

/// The string catalogue. Resolved at runtime rather than through `Bundle.module`, because
/// that symbol only exists inside a SwiftPM build -- the test harness compiles these files
/// on their own and would not link. Falls back to the key, which makes a missing translation
/// loud instead of silent.
let catalogue: Bundle = {
    if let u = Bundle.main.url(forResource: "Presort_Presort", withExtension: "bundle"),
       let b = Bundle(url: u) { return b }
    return .main
}()

/// Everything the model reads and everything the user reads comes through here, so switching
/// the system language switches the prompts along with the interface.
func t(_ key: String) -> String {
    catalogue.localizedString(forKey: key, value: key, table: nil)
}

/// What the app looks for. Every point is one question to the model.
///
/// The user may edit the description -- what counts and what does not -- but not the form
/// the answer has to come back in. That form is exactly what the app checks; anyone allowed
/// to rewrite it writes the check away. Which is why `systeemtekst` puts the preamble and the
/// schema around it itself.
struct Detector: Identifiable, Codable, Hashable {
    /// The two shapes the app can check and create. There are no more: an appointment has a
    /// start and an end, a reminder has a final date. Anything the user invents falls into
    /// one of the two.
    enum Kind: String, Codable, CaseIterable, Identifiable {
        // Spelled out: these end up in herkenners.json for the user's own points.
        case event = "afspraak"
        case reminder = "herinnering"
        var id: String { rawValue }
        var name: String { t(self == .event ? "shape.event" : "shape.reminder") }
        var category: Proposal.Category { self == .event ? .event : .reminder }
    }

    var id: String
    var name: String
    var summary: String
    var kind: Kind
    var enabled: Bool
    var instruction: String
    var own: Bool = false

    /// The field names in `herkenners.json`, spelled out so a rename here cannot throw
    /// away the points somebody wrote themselves.
    enum CodingKeys: String, CodingKey {
        case id = "id"
        case name = "naam"
        case summary = "uitleg"
        case kind = "vorm"
        case enabled = "aan"
        case instruction = "instructie"
        case own = "eigen"
    }
}

extension Detector {
    /// From the app, not editable: without these lines email text is indistinguishable from
    /// an instruction as far as the model is concerned.
    static var preamble: String { t("prompt.preamble") }

    /// From the app, not editable: `Scanner` depends on this. The JSON keys stay the same in
    /// every language -- only the prose around them is translated, and the prose is what
    /// decides which language the model answers in.
    var schema: String { t(kind == .event ? "schema.event" : "schema.reminder") }

    static var closing: String { t("prompt.closing") }

    /// What actually goes to the model.
    var systemText: String {
        """
        \(Detector.preamble)

        \(t("prompt.watch")) — \(name):
        \(instruction)

        \(t("prompt.reply"))
        \(schema)

        \(Detector.closing)
        """
    }
}

// MARK: what ships with it

extension Detector {
    /// The points the app brings along itself. The first two are on: that is what the app did
    /// before there was anything to choose. The rest are off, because every point that is on
    /// means one extra question per message.
    ///
    /// The ids are stable and never translated -- they are the keys under which the user's
    /// own changes are stored. Only what you read comes from the string catalogue.
    static let builtInIds = ["afspraak", "actie", "rekening", "verloopt", "ophalen", "reis"]

    static var builtIn: [Detector] {
        builtInIds.map { id in
            Detector(
                id: id,
                name: t("detector.\(id).name"),
                summary: t("detector.\(id).summary"),
                kind: (id == "afspraak" || id == "reis") ? .event : .reminder,
                enabled: id == "afspraak" || id == "actie",
                instruction: t("detector.\(id).instruction"))
        }
    }

    /// The starting point for a point the user adds themselves.
    static func new() -> Detector {
        Detector(id: UUID().uuidString,
                  name: t("detector.new.name"),
                  summary: "",
                  kind: .reminder,
                  enabled: false,
                  instruction: t("detector.new.instruction"),
                  own: true)
    }
}

// MARK: storing

/// Stores only what the user changed, not the whole list. Otherwise the saved state
/// freezes today's wording, and nobody would ever see an improved built-in description --
/// or a translation, now that the descriptions come from the string catalogue.
@MainActor
final class Detectors: ObservableObject {
    @Published private(set) var all: [Detector] = []

    var active: [Detector] { all.filter(\.enabled) }

    private struct Change: Codable {
        var enabled: Bool?
        var instruction: String?

        enum CodingKeys: String, CodingKey {
            case enabled = "aan"
            case instruction = "instructie"
        }
    }

    private struct Stored: Codable {
        var changes: [String: Change] = [:]
        var own: [Detector] = []

        enum CodingKeys: String, CodingKey {
            case changes = "aanpassingen"
            case own = "eigen"
        }
    }

    private var stored = Stored()
    private let file: URL
    private var saveTask: Task<Void, Never>?

    /// `map` exists for the tests: they must not write into the real settings file. Done
    /// once, and it wiped a configuration somebody had set by hand.
    init(folder: URL? = nil) {
        let folder = folder ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Presort", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("herkenners.json")

        if let data = try? Data(contentsOf: file),
           let s = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = s
        }
        rebuild()

        // Keystrokes are written out on a delay. Quit the app within that window and your
        // last sentence is gone -- which is why quitting flushes as well.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    private func rebuild() {
        var list = Detector.builtIn.map { h -> Detector in
            var h = h
            if let a = stored.changes[h.id] {
                if let enabled = a.enabled { h.enabled = enabled }
                if let i = a.instruction { h.instruction = i }
            }
            return h
        }
        list.append(contentsOf: stored.own)
        all = list
    }

    /// Has the built-in text been edited? Decides whether "restore the default" is of any use.
    func isEdited(_ id: String) -> Bool {
        stored.changes[id]?.instruction != nil
    }

    // MARK: changing

    func set(_ id: String, enabled: Bool) {
        if let i = stored.own.firstIndex(where: { $0.id == id }) {
            stored.own[i].enabled = enabled
        } else {
            stored.changes[id, default: Change()].enabled = enabled
        }
        rebuild()
        save()
    }

    func edit(_ id: String, instruction: String) {
        if let i = stored.own.firstIndex(where: { $0.id == id }) {
            stored.own[i].instruction = instruction
        } else {
            stored.changes[id, default: Change()].instruction = instruction
        }
        rebuild()
        saveSoon()
    }

    /// Only for the user's own points: the built-in names are the app's own vocabulary.
    func rename(_ id: String, name: String? = nil, summary: String? = nil, kind: Detector.Kind? = nil) {
        guard let i = stored.own.firstIndex(where: { $0.id == id }) else { return }
        if let name { stored.own[i].name = name }
        if let summary { stored.own[i].summary = summary }
        if let kind { stored.own[i].kind = kind }
        rebuild()
        saveSoon()
    }

    func restore(_ id: String) {
        stored.changes[id]?.instruction = nil
        rebuild()
        save()
    }

    @discardableResult
    func add() -> Detector {
        let h = Detector.new()
        stored.own.append(h)
        rebuild()
        save()
        return h
    }

    func remove(_ id: String) {
        stored.own.removeAll { $0.id == id }
        rebuild()
        save()
    }

    // MARK: writing

    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        saveTask?.cancel()
        let c = JSONEncoder()
        c.outputFormatting = .prettyPrinted
        guard let data = try? c.encode(stored) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
