import Foundation

/// How far back the app looks in the mailbox. Fixed steps rather than a free number:
/// "how far back" is something you think about in weeks and months, not in days.
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
        case .week:      return "Last 7 days"
        case .tweeWeken: return "Last 14 days"
        case .maand:     return "Last month"
        case .kwartaal:  return "Last quarter"
        case .halfJaar:  return "Last six months"
        case .jaar:      return "Last year"
        }
    }

    /// Short enough for the toolbar.
    var kort: String {
        switch self {
        case .week: return "7 days"
        case .tweeWeken: return "14 days"
        case .maand: return "1 month"
        case .kwartaal: return "quarter"
        case .halfJaar: return "6 months"
        case .jaar: return "year"
        }
    }

    static func dichtstbij(_ dagen: Int) -> Terugkijken {
        allCases.min(by: { abs($0.rawValue - dagen) < abs($1.rawValue - dagen) }) ?? .week
    }
}

/// How often the app checks by itself. Fixed steps here too: this is about "a few times
/// a day" or "as soon as something arrives", not about minutes.
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
        case .uit:      return "Only when I ask"
        case .kwartier: return "Every 15 minutes"
        case .halfUur:  return "Every half hour"
        case .uur:      return "Every hour"
        case .vierUur:  return "Every four hours"
        case .dag:      return "Twice a day"
        }
    }

    static func dichtstbij(_ minuten: Int) -> Ritme {
        allCases.min(by: { abs($0.rawValue - minuten) < abs($1.rawValue - minuten) }) ?? .uit
    }
}

/// How much earlier than the deadline you get nudged. A reminder that fires on the final
/// day is usually too late: getting a parcel back means a trip to a drop-off point.
enum Voorsprong: Int, CaseIterable, Identifiable {
    case opDeDagZelf = 0
    case eenDag = 1
    case tweeDagen = 2
    case drieDagen = 3
    case week = 7

    var id: Int { rawValue }

    var naam: String {
        switch self {
        case .opDeDagZelf: return "On the day itself"
        case .eenDag:      return "One day early"
        case .tweeDagen:   return "Two days early"
        case .drieDagen:   return "Three days early"
        case .week:        return "One week early"
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

    /// The same value, but as a choice from the list.
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

    /// Free function: init() may not call a method on self yet.
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
