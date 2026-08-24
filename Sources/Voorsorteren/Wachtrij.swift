import Foundation

/// Wat de app heeft gevonden, en wat de gebruiker daarmee deed.
/// Een besluit wist een voorstel niet -- het zet er een status naast. Zo blijft
/// zichtbaar wat er is voorgesteld, ook wat je hebt weggegooid.
struct Voorstel: Identifiable, Codable, Hashable {
    enum Soort: String, Codable { case afspraak, herinnering, overgeslagen }
    enum Status: String, Codable { case open, goedgekeurd, geweigerd, mislukt }

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

    var reden: String = ""        // bij overgeslagen: waarom er niets in zat
    var itemId: String = ""       // na goedkeuring: het aangemaakte item
    var fout: String = ""

    /// Welk punt dit vond. Optioneel, en dat is opzet: voorstellen van vóór de
    /// instelbare punten missen het veld, en een niet-optioneel veld zou het
    /// hele opgeslagen bestand onleesbaar maken.
    var herkenner: String?

    /// Hoe zeker het model zei te zijn: "hoog", "midden" of "laag". Om dezelfde
    /// reden optioneel. Alleen "hoog" mag er vanzelf in.
    var zekerheid: String?
}

@MainActor
final class Wachtrij: ObservableObject {
    @Published private(set) var items: [Voorstel] = []

    /// De nagekeken berichten-ids, oudste eerst. De volgorde is het punt: bij het
    /// snoeien moeten de oudste eruit, en een Set heeft geen volgorde -- die gooide
    /// willekeurige ids weg, waarna die berichten opnieuw langs het model gingen.
    @Published private(set) var geziene: [String] = []

    /// Alleen om snel te kunnen opzoeken; loopt altijd gelijk met `geziene`.
    private var gezienSnel: Set<String> = []

    /// Boven `maxGeziene` wordt er teruggesnoeid tot `behoudGeziene`, oudste eerst.
    private static let maxGeziene = 3000
    private static let behoudGeziene = 2000

    private let bestand: URL

    /// `map` is er voor de proeven, zodat die niet in de echte wachtrij graaien.
    init(map: URL? = nil) {
        let map = map ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voorsorteren", isDirectory: true)
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

    /// Houdt de lijst binnen de perken zonder de volgorde te verliezen.
    private func snoeiGeziene() {
        guard geziene.count > Wachtrij.maxGeziene else { return }
        geziene.removeFirst(geziene.count - Wachtrij.behoudGeziene)
        gezienSnel = Set(geziene)
    }

    /// Vergeet welke berichten al zijn nagekeken, zodat ze opnieuw langs het
    /// model gaan. Nodig zodra je een omschrijving hebt bijgesteld: anders zie
    /// je nooit of je verbetering werkt, want al gezien is al gezien. De
    /// voorstellen zelf blijven staan.
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

    // MARK: bewaren

    private struct Schijf: Codable {
        var items: [Voorstel]
        var geziene: [String]
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
        // Een oud bestand komt uit een Set en is dus ongeordend; wat erin staat
        // klopt nog wel. Dubbelen eruit, de rest houdt de volgorde van het bestand.
        geziene = []
        gezienSnel = []
        for id in s.geziene where gezienSnel.insert(id).inserted {
            geziene.append(id)
        }
        snoeiGeziene()
    }
}
