import Foundation

/// What the app found, and what the user did with it. A decision does not erase a
/// proposal -- it puts a status next to it, so what was proposed stays visible, including
/// the things you threw away.
struct Proposal: Identifiable, Codable, Hashable {
    /// The rawValues are written to disk, so they are spelled out rather than derived from
    /// the case names: renaming a case must never make an existing file unreadable.
    enum Category: String, Codable {
        case event = "afspraak"
        case reminder = "herinnering"
        case document = "document"
        case skipped = "overgeslagen"
    }
    /// Spelled out for the same reason. For the screen there is `shown`.
    enum Status: String, Codable {
        case waiting = "open"
        case filed = "goedgekeurd"
        case discarded = "geweigerd"
        case failed = "mislukt"

        /// What the user reads. Kept apart from the stored value on purpose -- and read
        /// from the catalogue, so it is not the one corner of the window still in English.
        var shown: String {
            switch self {
            case .waiting:   return t("status.waiting")
            case .filed:     return t("status.filed")
            case .discarded: return t("status.discarded")
            case .failed:    return t("status.failed")
            }
        }
    }

    var id: String = UUID().uuidString
    var time: Date = Date()
    var category: Category
    var status: Status = .waiting

    var sender: String = ""
    var subject: String = ""

    var title: String = ""
    var start: Date?
    var end: Date?
    var location: String = ""
    var dueDate: Date?
    var amount: String = ""
    var note: String = ""

    var reason: String = ""        // when skipped: why there was nothing in it
    var itemId: String = ""       // after approval: the item that was created
    var error: String = ""

    /// Which detector found this. Optional on purpose: proposals from before the
    /// configurable detectors lack the field, and a non-optional one would make the whole
    /// saved file unreadable.
    var detector: String?

    /// How certain the model said it was: "hoog", "midden" or "laag". Optional for the
    /// same reason. Only "hoog" may be filed automatically.
    var confidence: String?

    /// The message this came out of, so its attachment can still be fetched after the fact
    /// -- a document is only downloaded once you approve it, not while scanning.
    var messageId: String?
    /// Which attachment of that message, and what the sender called it.
    var attachmentIndex: Int?
    var attachmentName: String?
    /// Words the model pulled out of the mail. Matched against tags that already exist when
    /// filing; never used to invent one.
    var keywords: [String]?
    /// The organisation the document is from, as the model read it off the mail -- "British
    /// Gas" rather than "British Gas <billing@britishgas.co.uk>". An archive wants the name.
    var correspondent: String?

    /// Which destination filed this. Optional, like the two above: proposals from before
    /// there was more than one destination have no answer, and everything back then went
    /// to the calendar.
    var destination: String?

    /// Why nothing came of a message, and what became of one that did.
    ///
    /// These are stored, so they are codes and not sentences. Writing the sentence into the
    /// file was the old way, and it froze the wording of the day it was written: rephrasing
    /// it left every existing row saying the old thing forever, and a change of language
    /// left them in the old language. Anything unrecognised is shown as it stands, which is
    /// what keeps those older rows readable.
    enum Note {
        static let noContent = "no-content"
        static let nothingRelevant = "nothing-relevant"
        static let alreadyThere = "already-there"
        static let undone = "undone"
        static let noDestination = "no-destination"

        static func text(_ raw: String) -> String {
            switch code(raw) {
            case noContent:       return t("skip.noContent")
            case nothingRelevant: return t("skip.nothingRelevant")
            case alreadyThere:    return t("status.alreadyThere")
            case undone:          return t("status.undone")
            case noDestination:   return t("status.noDestination")
            default:              return raw
            }
        }

        /// Rows written before these were codes still carry a whole sentence, in whatever
        /// language was current at the time. Recognising the ones this app itself wrote
        /// keeps an existing list readable instead of half translated. Anything else is
        /// left alone: it is probably a message from a server, and inventing a code for it
        /// would be guessing.
        private static func code(_ raw: String) -> String {
            if let known = spelledOut[raw] { return known }
            // "niets van de 6 punten", "none of the 6 points", "keiner der 6 Punkte"
            if raw.range(of: "[0-9]+ +(punten|points|Punkte)", options: .regularExpression) != nil {
                return nothingRelevant
            }
            // The single-detector wording: "geen afspraken", "no appointments".
            for start in ["geen ", "no ", "aucun", "kein "] where raw.hasPrefix(start) {
                return nothingRelevant
            }
            return raw
        }

        private static let spelledOut: [String: String] = [
            "no readable content": noContent, "geen leesbare inhoud": noContent,
            "aucun contenu lisible": noContent, "kein lesbarer Inhalt": noContent,
            "already there": alreadyThere, "stond er al": alreadyThere,
            "déjà présent": alreadyThere, "war schon da": alreadyThere,
            "undone": undone, "teruggedraaid": undone,
            "annulé": undone, "rückgängig gemacht": undone,
        ]
    }

    var reasonText: String { Note.text(reason) }
    var errorText: String { Note.text(error) }

    /// The names of the fields in `voorstellen.json`, spelled out so that renaming a
    /// property here cannot silently orphan everything the user has already collected.
    enum CodingKeys: String, CodingKey {
        case id = "id"
        case time = "tijd"
        case category = "soort"
        case status = "status"
        case sender = "afzender"
        case subject = "onderwerp"
        case title = "titel"
        case start = "begin"
        case end = "eind"
        case location = "locatie"
        case dueDate = "uiterlijk"
        case amount = "bedrag"
        case note = "notitie"
        case reason = "reden"
        case itemId = "itemId"
        case error = "fout"
        case detector = "herkenner"
        case confidence = "zekerheid"
        case messageId = "berichtId"
        case attachmentIndex = "bijlageNr"
        case attachmentName = "bijlageNaam"
        case keywords = "trefwoorden"
        case correspondent = "correspondent"
        case destination = "bestemming"
    }
}

@MainActor
final class Queue: ObservableObject {
    @Published private(set) var items: [Proposal] = []

    /// Ids of messages already checked, oldest first. The order is the point: pruning has
    /// to drop the oldest, and a Set has no order -- it threw away random ids, after which
    /// those messages went past the model all over again.
    @Published private(set) var seen: [String] = []

    /// Only for fast lookup; always kept in step with `geziene`.
    private var seenFast: Set<String> = []

    /// Above `maxGeziene` it is pruned back to `behoudGeziene`, oldest first.
    private static let maxSeen = 3000
    private static let keepSeen = 2000

    private let file: URL

    /// `map` exists for the tests, so they do not rummage through the real queue.
    init(folder: URL? = nil) {
        let folder = folder ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Presort", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("voorstellen.json")
        load()
    }

    var waiting: [Proposal] {
        items.filter { $0.status == .waiting && $0.category != .skipped }
            .sorted { $0.time > $1.time }
    }

    var handled: [Proposal] {
        items.filter { $0.status != .waiting && $0.category != .skipped }
            .sorted { $0.time > $1.time }
    }

    var skipped: [Proposal] {
        items.filter { $0.category == .skipped }.sorted { $0.time > $1.time }
    }

    func isSeen(_ messageId: String) -> Bool { seenFast.contains(messageId) }

    func markSeen(_ messageId: String) {
        guard seenFast.insert(messageId).inserted else { return }
        seen.append(messageId)
        pruneSeen()
        save()
    }

    /// Keeps the list bounded without losing the ordering.
    private func pruneSeen() {
        guard seen.count > Queue.maxSeen else { return }
        seen.removeFirst(seen.count - Queue.keepSeen)
        seenFast = Set(seen)
    }

    /// Forget which messages have already been checked, so they go past the model again.
    /// Needed as soon as you adjust a description: otherwise you never see whether your
    /// improvement works, because seen is seen. The proposals themselves stay.
    func forgetSeen() {
        seen.removeAll()
        seenFast.removeAll()
        save()
    }

    func add(_ v: Proposal) {
        items.append(v)
        if items.count > 500 { items.removeFirst(items.count - 500) }
        save()
    }

    func update(_ id: String, _ change: (inout Proposal) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        save()
    }

    // MARK: persistence

    private struct Stored: Codable {
        var items: [Proposal]
        var seen: [String]

        enum CodingKeys: String, CodingKey {
            case items = "items"
            case seen = "geziene"
        }
    }

    private func save() {
        let s = Stored(items: items, seen: seen)
        let c = JSONEncoder()
        c.dateEncodingStrategy = .iso8601
        c.outputFormatting = .prettyPrinted
        guard let data = try? c.encode(s) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: file.path)
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let s = try? d.decode(Stored.self, from: data) else { return }
        items = s.items
        // An older file came from a Set and is therefore unordered; its contents are still
        // correct. Drop duplicates, the rest keeps the order of the file.
        seen = []
        seenFast = []
        for id in s.seen where seenFast.insert(id).inserted {
            seen.append(id)
        }
        pruneSeen()
    }
}
