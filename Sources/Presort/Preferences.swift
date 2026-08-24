import Foundation

/// How far back the app looks in the mailbox. Fixed steps rather than a free number:
/// "how far back" is something you think about in weeks and months, not in days.
enum LookBack: Int, CaseIterable, Identifiable {
    case week = 7
    case twoWeeks = 14
    case month = 30
    case quarter = 91
    case halfYear = 182
    case year = 365

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .week:      return t("lookback.week")
        case .twoWeeks: return t("lookback.twoWeeks")
        case .month:     return t("lookback.month")
        case .quarter:  return t("lookback.quarter")
        case .halfYear:  return t("lookback.halfYear")
        case .year:      return t("lookback.year")
        }
    }

    /// Short enough for the toolbar.
    var short: String {
        switch self {
        case .week:      return t("lookback.short.week")
        case .twoWeeks: return t("lookback.short.twoWeeks")
        case .month:     return t("lookback.short.month")
        case .quarter:  return t("lookback.short.quarter")
        case .halfYear:  return t("lookback.short.halfYear")
        case .year:      return t("lookback.short.year")
        }
    }

    static func nearest(_ days: Int) -> LookBack {
        allCases.min(by: { abs($0.rawValue - days) < abs($1.rawValue - days) }) ?? .week
    }
}

/// How often the app checks by itself. Fixed steps here too: this is about "a few times
/// a day" or "as soon as something arrives", not about minutes.
enum Rhythm: Int, CaseIterable, Identifiable {
    case off = 0
    case quarterHour = 15
    case halfHour = 30
    case hour = 60
    case fourHours = 240
    case twiceADay = 720

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .off:      return t("rhythm.off")
        case .quarterHour: return t("rhythm.quarterHour")
        case .halfHour:  return t("rhythm.halfHour")
        case .hour:      return t("rhythm.hour")
        case .fourHours:  return t("rhythm.fourHours")
        case .twiceADay:      return t("rhythm.twiceADay")
        }
    }

    static func nearest(_ minutes: Int) -> Rhythm {
        allCases.min(by: { abs($0.rawValue - minutes) < abs($1.rawValue - minutes) }) ?? .off
    }
}

/// How much earlier than the deadline you get nudged. A reminder that fires on the final
/// day is usually too late: getting a parcel back means a trip to a drop-off point.
enum LeadTime: Int, CaseIterable, Identifiable {
    case sameDay = 0
    case oneDay = 1
    case twoDays = 2
    case threeDays = 3
    case week = 7

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .sameDay: return t("lead.sameDay")
        case .oneDay:      return t("lead.oneDay")
        case .twoDays:   return t("lead.twoDays")
        case .threeDays:   return t("lead.threeDays")
        case .week:        return t("lead.week")
        }
    }

    static func nearest(_ days: Int) -> LeadTime {
        allCases.min(by: { abs($0.rawValue - days) < abs($1.rawValue - days) }) ?? .threeDays
    }
}

@MainActor
final class Preferences: ObservableObject {
    @Published var endpoint: String { didSet { save("eindpunt", endpoint) } }
    @Published var key: String { didSet { save("sleutel", key) } }
    @Published var model: String { didSet { save("model", model) } }
    @Published var account: String { didSet { save("account", account) } }
    @Published var mailbox: String { didSet { save("postvak", mailbox) } }
    @Published var days: Int { didSet { save("dagen", String(days)) } }

    /// The same value, but as a choice from the list.
    var period: LookBack {
        get { LookBack.nearest(days) }
        set { days = newValue.rawValue }
    }
    @Published var calendarName: String { didSet { save("agendaNaam", calendarName) } }
    @Published var onlyHighConfidence: Bool { didSet { save("zekerheid", onlyHighConfidence ? "1" : "0") } }

    @Published var fileAutomatically: Bool { didSet { save("zetZelfIn", fileAutomatically ? "1" : "0") } }

    @Published var leadDays: Int { didSet { save("voorsprong", String(leadDays)) } }

    var leadTime: LeadTime {
        get { LeadTime.nearest(leadDays) }
        set { leadDays = newValue.rawValue }
    }

    @Published var rhythmMinutes: Int { didSet { save("ritme", String(rhythmMinutes)) } }
    @Published var notificationsOn: Bool { didSet { save("meldingen", notificationsOn ? "1" : "0") } }

    var rhythm: Rhythm {
        get { Rhythm.nearest(rhythmMinutes) }
        set { rhythmMinutes = newValue.rawValue }
    }

    private let d = UserDefaults.standard

    init() {
        let read = Preferences.reader
        endpoint = read("eindpunt", "http://127.0.0.1:11434/v1")
        key = read("sleutel", "")
        model = read("model", "")
        account = read("account", "iCloud")
        mailbox = read("postvak", "INBOX")
        days = Int(read("dagen", "3")) ?? 3
        calendarName = read("agendaNaam", "Presort")
        onlyHighConfidence = read("zekerheid", "1") == "1"
        fileAutomatically = read("zetZelfIn", "0") == "1"
        leadDays = Int(read("voorsprong", "3")) ?? 3
        rhythmMinutes = Int(read("ritme", "0")) ?? 0
        notificationsOn = read("meldingen", "1") == "1"
    }

    /// Free function: init() may not call a method on self yet.
    private static func reader(_ k: String, _ fallback: String) -> String {
        UserDefaults.standard.string(forKey: k) ?? fallback
    }

    private func save(_ key: String, _ value: String) {
        d.set(value, forKey: key)
    }

    var isConfigured: Bool {
        !endpoint.trimmingCharacters(in: .whitespaces).isEmpty &&
        !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
