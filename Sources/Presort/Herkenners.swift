import AppKit
import Foundation

/// The string catalogue. Resolved at runtime rather than through `Bundle.module`, because
/// that symbol only exists inside a SwiftPM build -- the test harness compiles these files
/// on their own and would not link. Falls back to the key, which makes a missing translation
/// loud instead of silent.
let catalogus: Bundle = {
    if let u = Bundle.main.url(forResource: "Presort_Presort", withExtension: "bundle"),
       let b = Bundle(url: u) { return b }
    return .main
}()

/// Everything the model reads and everything the user reads comes through here, so switching
/// the system language switches the prompts along with the interface.
func t(_ sleutel: String) -> String {
    catalogus.localizedString(forKey: sleutel, value: sleutel, table: nil)
}

/// What the app looks for. Every point is one question to the model.
///
/// The user may edit the description -- what counts and what does not -- but not the form
/// the answer has to come back in. That form is exactly what the app checks; anyone allowed
/// to rewrite it writes the check away. Which is why `systeemtekst` puts the preamble and the
/// schema around it itself.
struct Herkenner: Identifiable, Codable, Hashable {
    /// The two shapes the app can check and create. There are no more: an appointment has a
    /// start and an end, a reminder has a final date. Anything the user invents falls into
    /// one of the two.
    enum Vorm: String, Codable, CaseIterable, Identifiable {
        case afspraak, herinnering
        var id: String { rawValue }
        var naam: String { t(self == .afspraak ? "shape.event" : "shape.reminder") }
        var soort: Voorstel.Soort { self == .afspraak ? .afspraak : .herinnering }
    }

    var id: String
    var naam: String
    var uitleg: String
    var vorm: Vorm
    var aan: Bool
    var instructie: String
    var eigen: Bool = false
}

extension Herkenner {
    /// From the app, not editable: without these lines email text is indistinguishable from
    /// an instruction as far as the model is concerned.
    static var aanhef: String { t("prompt.preamble") }

    /// From the app, not editable: `Scanner` depends on this. The JSON keys stay the same in
    /// every language -- only the prose around them is translated, and the prose is what
    /// decides which language the model answers in.
    var schema: String { t(vorm == .afspraak ? "schema.event" : "schema.reminder") }

    static var slot: String { t("prompt.closing") }

    /// What actually goes to the model.
    var systeemtekst: String {
        """
        \(Herkenner.aanhef)

        \(t("prompt.watch")) — \(naam):
        \(instructie)

        \(t("prompt.reply"))
        \(schema)

        \(Herkenner.slot)
        """
    }
}

// MARK: what ships with it

extension Herkenner {
    /// The points the app brings along itself. The first two are on: that is what the app did
    /// before there was anything to choose. The rest are off, because every point that is on
    /// means one extra question per message.
    ///
    /// The ids are stable and never translated -- they are the keys under which the user's
    /// own changes are stored. Only what you read comes from the string catalogue.
    static let builtInIds = ["afspraak", "actie", "rekening", "verloopt", "ophalen", "reis"]

    static var ingebouwd: [Herkenner] {
        builtInIds.map { id in
            Herkenner(
                id: id,
                naam: t("detector.\(id).name"),
                uitleg: t("detector.\(id).summary"),
                vorm: (id == "afspraak" || id == "reis") ? .afspraak : .herinnering,
                aan: id == "afspraak" || id == "actie",
                instructie: t("detector.\(id).instruction"))
        }
    }

    /// The starting point for a point the user adds themselves.
    static func nieuw() -> Herkenner {
        Herkenner(id: UUID().uuidString,
                  naam: t("detector.new.name"),
                  uitleg: "",
                  vorm: .herinnering,
                  aan: false,
                  instructie: t("detector.new.instruction"),
                  eigen: true)
    }
}

// MARK: bewaren

/// Stores only what the user changed, not the whole list. Otherwise the saved state
/// freezes today's wording, and nobody would ever see an improved built-in description --
/// or a translation, now that the descriptions come from the string catalogue.
@MainActor
final class Herkenners: ObservableObject {
    @Published private(set) var alle: [Herkenner] = []

    var actief: [Herkenner] { alle.filter(\.aan) }

    private struct Aanpassing: Codable {
        var aan: Bool?
        var instructie: String?
    }

    private struct Schijf: Codable {
        var aanpassingen: [String: Aanpassing] = [:]
        var eigen: [Herkenner] = []
    }

    private var schijf = Schijf()
    private let bestand: URL
    private var bewaarTaak: Task<Void, Never>?

    /// `map` exists for the tests: they must not write into the real settings file. Done
    /// once, and it wiped a configuration somebody had set by hand.
    init(map: URL? = nil) {
        let map = map ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Presort", isDirectory: true)
        try? FileManager.default.createDirectory(at: map, withIntermediateDirectories: true)
        bestand = map.appendingPathComponent("herkenners.json")

        if let data = try? Data(contentsOf: bestand),
           let s = try? JSONDecoder().decode(Schijf.self, from: data) {
            schijf = s
        }
        bouwOp()

        // Keystrokes are written out on a delay. Quit the app within that window and your
        // last sentence is gone -- which is why quitting flushes as well.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.bewaar() }
        }
    }

    private func bouwOp() {
        var lijst = Herkenner.ingebouwd.map { h -> Herkenner in
            var h = h
            if let a = schijf.aanpassingen[h.id] {
                if let aan = a.aan { h.aan = aan }
                if let i = a.instructie { h.instructie = i }
            }
            return h
        }
        lijst.append(contentsOf: schijf.eigen)
        alle = lijst
    }

    /// Is de ingebouwde tekst aangepast? Bepaalt of "herstel de standaard" nut heeft.
    func isAangepast(_ id: String) -> Bool {
        schijf.aanpassingen[id]?.instructie != nil
    }

    // MARK: veranderen

    func zet(_ id: String, aan: Bool) {
        if let i = schijf.eigen.firstIndex(where: { $0.id == id }) {
            schijf.eigen[i].aan = aan
        } else {
            schijf.aanpassingen[id, default: Aanpassing()].aan = aan
        }
        bouwOp()
        bewaar()
    }

    func bewerk(_ id: String, instructie: String) {
        if let i = schijf.eigen.firstIndex(where: { $0.id == id }) {
            schijf.eigen[i].instructie = instructie
        } else {
            schijf.aanpassingen[id, default: Aanpassing()].instructie = instructie
        }
        bouwOp()
        bewaarStraks()
    }

    /// Only for the user's own points: the built-in names are the app's own vocabulary.
    func hernoem(_ id: String, naam: String? = nil, uitleg: String? = nil, vorm: Herkenner.Vorm? = nil) {
        guard let i = schijf.eigen.firstIndex(where: { $0.id == id }) else { return }
        if let naam { schijf.eigen[i].naam = naam }
        if let uitleg { schijf.eigen[i].uitleg = uitleg }
        if let vorm { schijf.eigen[i].vorm = vorm }
        bouwOp()
        bewaarStraks()
    }

    func herstel(_ id: String) {
        schijf.aanpassingen[id]?.instructie = nil
        bouwOp()
        bewaar()
    }

    @discardableResult
    func voegToe() -> Herkenner {
        let h = Herkenner.nieuw()
        schijf.eigen.append(h)
        bouwOp()
        bewaar()
        return h
    }

    func verwijder(_ id: String) {
        schijf.eigen.removeAll { $0.id == id }
        bouwOp()
        bewaar()
    }

    // MARK: schrijven

    private func bewaarStraks() {
        bewaarTaak?.cancel()
        bewaarTaak = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.bewaar()
        }
    }

    private func bewaar() {
        bewaarTaak?.cancel()
        let c = JSONEncoder()
        c.outputFormatting = .prettyPrinted
        guard let data = try? c.encode(schijf) else { return }
        try? data.write(to: bestand, options: .atomic)
    }
}
