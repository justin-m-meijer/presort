import Foundation

/// Hoe ver de app terugkijkt in het postvak. Vaste stappen in plaats van een
/// vrij getal: bij "hoe ver terug" denk je in weken en maanden, niet in dagen.
enum Terugkijken: Int, CaseIterable, Identifiable {
    case week = 7
    case tweeWeken = 14
    case maand = 30
    case kwartaal = 91
    case halfJaar = 182
    case jaar = 365

    var id: Int { rawValue }

    var naam: String {
        switch self {
        case .week:      return "Afgelopen 7 dagen"
        case .tweeWeken: return "Afgelopen 14 dagen"
        case .maand:     return "Afgelopen maand"
        case .kwartaal:  return "Afgelopen kwartaal"
        case .halfJaar:  return "Afgelopen half jaar"
        case .jaar:      return "Afgelopen jaar"
        }
    }

    /// Kort genoeg voor de knoppenbalk.
    var kort: String {
        switch self {
        case .week: return "7 dagen"
        case .tweeWeken: return "14 dagen"
        case .maand: return "1 maand"
        case .kwartaal: return "kwartaal"
        case .halfJaar: return "half jaar"
        case .jaar: return "jaar"
        }
    }

    static func dichtstbij(_ dagen: Int) -> Terugkijken {
        allCases.min(by: { abs($0.rawValue - dagen) < abs($1.rawValue - dagen) }) ?? .week
    }
}

/// Hoe vaak de app uit zichzelf gaat kijken. Ook hier vaste stappen: het gaat
/// om "een paar keer per dag" of "zodra er iets binnenkomt", niet om minuten.
enum Ritme: Int, CaseIterable, Identifiable {
    case uit = 0
    case kwartier = 15
    case halfUur = 30
    case uur = 60
    case vierUur = 240
    case dag = 720

    var id: Int { rawValue }

    var naam: String {
        switch self {
        case .uit:      return "Alleen als ik erom vraag"
        case .kwartier: return "Elk kwartier"
        case .halfUur:  return "Elk half uur"
        case .uur:      return "Elk uur"
        case .vierUur:  return "Om de vier uur"
        case .dag:      return "Twee keer per dag"
        }
    }

    static func dichtstbij(_ minuten: Int) -> Ritme {
        allCases.min(by: { abs($0.rawValue - minuten) < abs($1.rawValue - minuten) }) ?? .uit
    }
}

/// Hoeveel eerder je een seintje krijgt dan de uiterste datum. Een herinnering
/// die op de laatste dag afgaat is meestal te laat: een pakket terugsturen kost
/// een rit naar het afhaalpunt.
enum Voorsprong: Int, CaseIterable, Identifiable {
    case opDeDagZelf = 0
    case eenDag = 1
    case tweeDagen = 2
    case drieDagen = 3
    case week = 7

    var id: Int { rawValue }

    var naam: String {
        switch self {
        case .opDeDagZelf: return "Op de dag zelf"
        case .eenDag:      return "Een dag van tevoren"
        case .tweeDagen:   return "Twee dagen van tevoren"
        case .drieDagen:   return "Drie dagen van tevoren"
        case .week:        return "Een week van tevoren"
        }
    }

    static func dichtstbij(_ dagen: Int) -> Voorsprong {
        allCases.min(by: { abs($0.rawValue - dagen) < abs($1.rawValue - dagen) }) ?? .drieDagen
    }
}

@MainActor
final class Instellingen: ObservableObject {
    @Published var eindpunt: String { didSet { bewaar("eindpunt", eindpunt) } }
    @Published var sleutel: String { didSet { bewaar("sleutel", sleutel) } }
    @Published var model: String { didSet { bewaar("model", model) } }
    @Published var account: String { didSet { bewaar("account", account) } }
    @Published var postvak: String { didSet { bewaar("postvak", postvak) } }
    @Published var dagen: Int { didSet { bewaar("dagen", String(dagen)) } }

    /// Dezelfde waarde, maar als keuze uit de lijst.
    var periode: Terugkijken {
        get { Terugkijken.dichtstbij(dagen) }
        set { dagen = newValue.rawValue }
    }
    @Published var agendaNaam: String { didSet { bewaar("agendaNaam", agendaNaam) } }
    @Published var alleenHogeZekerheid: Bool { didSet { bewaar("zekerheid", alleenHogeZekerheid ? "1" : "0") } }

    @Published var zetZelfIn: Bool { didSet { bewaar("zetZelfIn", zetZelfIn ? "1" : "0") } }

    @Published var voorsprongDagen: Int { didSet { bewaar("voorsprong", String(voorsprongDagen)) } }

    var voorsprong: Voorsprong {
        get { Voorsprong.dichtstbij(voorsprongDagen) }
        set { voorsprongDagen = newValue.rawValue }
    }

    @Published var ritmeMinuten: Int { didSet { bewaar("ritme", String(ritmeMinuten)) } }
    @Published var meldingen: Bool { didSet { bewaar("meldingen", meldingen ? "1" : "0") } }

    var ritme: Ritme {
        get { Ritme.dichtstbij(ritmeMinuten) }
        set { ritmeMinuten = newValue.rawValue }
    }

    private let d = UserDefaults.standard

    init() {
        let lees = Instellingen.lezer
        eindpunt = lees("eindpunt", "http://127.0.0.1:11434/v1")
        sleutel = lees("sleutel", "")
        model = lees("model", "")
        account = lees("account", "iCloud")
        postvak = lees("postvak", "INBOX")
        dagen = Int(lees("dagen", "3")) ?? 3
        agendaNaam = lees("agendaNaam", "Voorsorteren")
        alleenHogeZekerheid = lees("zekerheid", "1") == "1"
        zetZelfIn = lees("zetZelfIn", "0") == "1"
        voorsprongDagen = Int(lees("voorsprong", "3")) ?? 3
        ritmeMinuten = Int(lees("ritme", "0")) ?? 0
        meldingen = lees("meldingen", "1") == "1"
    }

    /// Vrije functie: in init() mag nog geen methode op self worden aangeroepen.
    private static func lezer(_ k: String, _ standaard: String) -> String {
        UserDefaults.standard.string(forKey: k) ?? standaard
    }

    private func bewaar(_ sleutel: String, _ waarde: String) {
        d.set(waarde, forKey: sleutel)
    }

    var isIngericht: Bool {
        !eindpunt.trimmingCharacters(in: .whitespaces).isEmpty &&
        !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
