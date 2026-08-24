import Foundation

/// What the app found, and what the user did with it. A decision does not erase a
/// proposal -- it puts a status next to it, so what was proposed stays visible, including
/// the things you threw away.
struct Voorstel: Identifiable, Codable, Hashable {
    /// The rawValues are written to disk, so they are spelled out rather than derived from
    /// the case names: renaming a case must never make an existing file unreadable.
    enum Soort: String, Codable {
        case afspraak = "afspraak"
        case herinnering = "herinnering"
        case overgeslagen = "overgeslagen"
    }
    /// Spelled out for the same reason. For the screen there is `getoond`.
    enum Status: String, Codable {
        case open = "open"
        case goedgekeurd = "goedgekeurd"
        case geweigerd = "geweigerd"
        case mislukt = "mislukt"

        /// What the user reads. Kept apart from the stored value on purpose.
        var getoond: String {
            switch self {
            case .open:        return "waiting"
            case .goedgekeurd: return "filed"
            case .geweigerd:   return "discarded"
            case .mislukt:     return "failed"
            }
        }
    }

    var id: String = UUID().uuidString
    var tijd: Date = Date()
    var soort: Soort
    var status: Status = .open

    var afzender: String = ""
    var onderwerp: String = ""

    var titel: String = ""
    var begin: Date?
    var eind: Date?
    var locatie: String = ""
    var uiterlijk: Date?
    var bedrag: String = ""
    var notitie: String = ""

    var reden: String = ""        // when skipped: why there was nothing in it
    var itemId: String = ""       // after approval: the item that was created
    var fout: String = ""

    /// Which detector found this. Optional on purpose: proposals from before the
    /// configurable detectors lack the field, and a non-optional one would make the whole
    /// saved file unreadable.
    var herkenner: String?

    /// How certain the model said it was: "hoog", "midden" or "laag". Optional for the
    /// same reason. Only "hoog" may be filed automatically.
    var zekerheid: String?

    /// The names of the fields in `voorstellen.json`, spelled out so that renaming a
    /// property here cannot silently orphan everything the user has already collected.
    enum CodingKeys: String, CodingKey {
        case id = "id"
        case tijd = "tijd"
        case soort = "soort"
        case status = "status"
        case afzender = "afzender"
        case onderwerp = "onderwerp"
        case titel = "titel"
        case begin = "begin"
        case eind = "eind"
        case locatie = "locatie"
        case uiterlijk = "uiterlijk"
        case bedrag = "bedrag"
        case notitie = "notitie"
        case reden = "reden"
        case itemId = "itemId"
        case fout = "fout"
        case herkenner = "herkenner"
        case zekerheid = "zekerheid"
    }
}

@MainActor
final class Wachtrij: ObservableObject {
    @Published private(set) var items: [Voorstel] = []

    /// Ids of messages already checked, oldest first. The order is the point: pruning has
    /// to drop the oldest, and a Set has no order -- it threw away random ids, after which
    /// those messages went past the model all over again.
    @Published private(set) var geziene: [String] = []

    /// Only for fast lookup; always kept in step with `geziene`.
    private var gezienSnel: Set<String> = []

    /// Above `maxGeziene` it is pruned back to `behoudGeziene`, oldest first.
    private static let maxGeziene = 3000
    private static let behoudGeziene = 2000

    private let bestand: URL

    /// `map` exists for the tests, so they do not rummage through the real queue.
    init(map: URL? = nil) {
        let map = map ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Presort", isDirectory: true)
        try? FileManager.default.createDirectory(at: map, withIntermediateDirectories: true)
        bestand = map.appendingPathComponent("voorstellen.json")
        laad()
    }

    var open: [Voorstel] {
        items.filter { $0.status == .open && $0.soort != .overgeslagen }
            .sorted { $0.tijd > $1.tijd }
    }

    var afgehandeld: [Voorstel] {
        items.filter { $0.status != .open && $0.soort != .overgeslagen }
            .sorted { $0.tijd > $1.tijd }
    }

    var overgeslagen: [Voorstel] {
        items.filter { $0.soort == .overgeslagen }.sorted { $0.tijd > $1.tijd }
    }

    func isGezien(_ berichtId: String) -> Bool { gezienSnel.contains(berichtId) }

    func markeerGezien(_ berichtId: String) {
        guard gezienSnel.insert(berichtId).inserted else { return }
        geziene.append(berichtId)
        snoeiGeziene()
        bewaar()
    }

    /// Keeps the list bounded without losing the ordering.
    private func snoeiGeziene() {
        guard geziene.count > Wachtrij.maxGeziene else { return }
        geziene.removeFirst(geziene.count - Wachtrij.behoudGeziene)
        gezienSnel = Set(geziene)
    }

    /// Forget which messages have already been checked, so they go past the model again.
    /// Needed as soon as you adjust a description: otherwise you never see whether your
    /// improvement works, because seen is seen. The proposals themselves stay.
    func vergeetGeziene() {
        geziene.removeAll()
        gezienSnel.removeAll()
        bewaar()
    }

    func voegToe(_ v: Voorstel) {
        items.append(v)
        if items.count > 500 { items.removeFirst(items.count - 500) }
        bewaar()
    }

    func werkBij(_ id: String, _ wijzig: (inout Voorstel) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        wijzig(&items[i])
        bewaar()
    }

    // MARK: persistence

    private struct Schijf: Codable {
        var items: [Voorstel]
        var geziene: [String]

        enum CodingKeys: String, CodingKey {
            case items = "items"
            case geziene = "geziene"
        }
    }

    private func bewaar() {
        let s = Schijf(items: items, geziene: geziene)
        let c = JSONEncoder()
        c.dateEncodingStrategy = .iso8601
        c.outputFormatting = .prettyPrinted
        guard let data = try? c.encode(s) else { return }
        try? data.write(to: bestand, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: bestand.path)
    }

    private func laad() {
        guard let data = try? Data(contentsOf: bestand) else { return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let s = try? d.decode(Schijf.self, from: data) else { return }
        items = s.items
        // An older file came from a Set and is therefore unordered; its contents are still
        // correct. Drop duplicates, the rest keeps the order of the file.
        geziene = []
        gezienSnel = []
        for id in s.geziene where gezienSnel.insert(id).inserted {
            geziene.append(id)
        }
        snoeiGeziene()
    }
}
