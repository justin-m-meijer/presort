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
        case .week:      return t("lookback.week")
        case .tweeWeken: return t("lookback.twoWeeks")
        case .maand:     return t("lookback.month")
        case .kwartaal:  return t("lookback.quarter")
        case .halfJaar:  return t("lookback.halfYear")
        case .jaar:      return t("lookback.year")
        }
    }

    /// Short enough for the toolbar.
    var kort: String {
        switch self {
        case .week:      return t("lookback.short.week")
        case .tweeWeken: return t("lookback.short.twoWeeks")
        case .maand:     return t("lookback.short.month")
        case .kwartaal:  return t("lookback.short.quarter")
        case .halfJaar:  return t("lookback.short.halfYear")
        case .jaar:      return t("lookback.short.year")
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
        case .uit:      return t("rhythm.off")
        case .kwartier: return t("rhythm.quarterHour")
        case .halfUur:  return t("rhythm.halfHour")
        case .uur:      return t("rhythm.hour")
        case .vierUur:  return t("rhythm.fourHours")
        case .dag:      return t("rhythm.twiceADay")
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
        case .opDeDagZelf: return t("lead.sameDay")
        case .eenDag:      return t("lead.oneDay")
        case .tweeDagen:   return t("lead.twoDays")
        case .drieDagen:   return t("lead.threeDays")
        case .week:        return t("lead.week")
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
        agendaNaam = lees("agendaNaam", "Presort")
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
