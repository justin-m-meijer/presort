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

    /// Models that only answer with thinking switched off, by name. Found by the model check
    /// and sent along as `chat_template_kwargs`. Not every server accepts that field, so it is
    /// never on by default.
    @Published var modelsWithoutThinking: [String] {
        didSet { save("zonderDenken", modelsWithoutThinking.joined(separator: "\n")) }
    }

    var thinkingOff: Bool { modelsWithoutThinking.contains(model) }

    func setThinkingOff(_ off: Bool, for name: String) {
        var list = modelsWithoutThinking.filter { $0 != name }
        if off { list.append(name) }
        if list != modelsWithoutThinking { modelsWithoutThinking = list }
    }

    var modelClient: ModelClient {
        ModelClient(endpoint: endpoint, key: key, model: model, thinkingOff: thinkingOff)
    }
    @Published var account: String { didSet { save("account", account) } }
    @Published var mailbox: String { didSet { save("postvak", mailbox) } }
    @Published var days: Int { didSet { save("dagen", String(days)) } }

    /// The same value, but as a choice from the list.
    var period: LookBack {
        get { LookBack.nearest(days) }
        set { days = newValue.rawValue }
    }
    @Published var calendarName: String { didSet { save("agendaNaam", calendarName) } }

    /// Off means: write into calendars the user already uses. Default on, and it stays a
    /// deliberate choice with a warning next to it rather than a quiet default.
    @Published var useOwnCalendar: Bool { didSet { save("eigenAgenda", useOwnCalendar ? "1" : "0") } }
    @Published var eventCalendarId: String { didSet { save("agendaId", eventCalendarId) } }
    @Published var reminderListId: String { didSet { save("lijstId", reminderListId) } }
    @Published var onlyHighConfidence: Bool { didSet { save("zekerheid", onlyHighConfidence ? "1" : "0") } }

    @Published var fileAutomatically: Bool { didSet { save("zetZelfIn", fileAutomatically ? "1" : "0") } }

    @Published var leadDays: Int { didSet { save("voorsprong", String(leadDays)) } }

    var leadTime: LeadTime {
        get { LeadTime.nearest(leadDays) }
        set { leadDays = newValue.rawValue }
    }

    /// Shown once, on the first launch. Kept here rather than in @AppStorage so it sits
    /// with everything else the app remembers about you.
    @Published var hasSeenWelcome: Bool { didSet { save("welkomGezien", hasSeenWelcome ? "1" : "0") } }

    // MARK: connections
    //
    // Each service outside the Mac gets its own block here. Paperless-ngx is the first, and
    // is written out flat rather than as a generic bag: a second connection wants its own
    // fields anyway, and a bag of strings would only postpone deciding what they are.

    @Published var paperlessOn: Bool { didSet { save("paperlessAan", paperlessOn ? "1" : "0") } }
    @Published var paperlessAddress: String { didSet { save("paperlessAdres", paperlessAddress) } }
    /// In the Keychain, not here: this one opens somebody's whole archive.
    ///
    /// Deliberately empty until something asks for it. Reading the Keychain blocks when the
    /// login keychain is locked -- it waits on a system dialog -- and a read on the launch
    /// path meant the app came up with no window and no menu bar at all. Alive, at nought
    /// per cent, waiting for a question nobody was shown. Nothing that can block belongs in
    /// the initialiser of something the first window is built from.
    @Published var paperlessToken: String = "" {
        didSet {
            guard !loadingToken else { return }
            Keychain.set(paperlessToken, for: "paperless-token")
        }
    }
    private var loadingToken = false
    private var tokenLoaded = false

    /// Fetches it once, off the main thread, when something actually needs it.
    func loadPaperlessToken() async {
        guard !tokenLoaded else { return }
        tokenLoaded = true
        let stored = await Task.detached(priority: .utility) {
            Keychain.get("paperless-token")
        }.value
        guard !stored.isEmpty else { return }
        loadingToken = true
        paperlessToken = stored
        loadingToken = false
    }
    @Published var paperlessTags: String { didSet { save("paperlessTags", paperlessTags) } }
    @Published var paperlessCreatesCorrespondents: Bool {
        didSet { save("paperlessCorrespondent", paperlessCreatesCorrespondents ? "1" : "0") }
    }

    /// The tag names as typed, comma separated, emptied of blanks.
    var paperlessTagList: [String] {
        paperlessTags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var paperlessConfig: Paperless.Config {
        Paperless.Config(address: paperlessAddress, token: paperlessToken,
                         tagNames: paperlessTagList,
                         createCorrespondent: paperlessCreatesCorrespondents)
    }

    var paperlessReady: Bool {
        paperlessOn
        && !paperlessAddress.trimmingCharacters(in: .whitespaces).isEmpty
        && !paperlessToken.isEmpty
    }

    // Parcel (parcelapp.net), the delivery tracker.

    @Published var parcelOn: Bool { didSet { save("parcelAan", parcelOn ? "1" : "0") } }
    /// In the Keychain like the Paperless token, and read as late, for the same reason.
    @Published var parcelKey: String = "" {
        didSet {
            guard !loadingParcelKey else { return }
            Keychain.set(parcelKey, for: "parcel-api-key")
        }
    }
    private var loadingParcelKey = false
    private var parcelKeyLoaded = false

    func loadParcelKey() async {
        guard !parcelKeyLoaded else { return }
        parcelKeyLoaded = true
        let stored = await Task.detached(priority: .utility) {
            Keychain.get("parcel-api-key")
        }.value
        guard !stored.isEmpty else { return }
        loadingParcelKey = true
        parcelKey = stored
        loadingParcelKey = false
    }

    /// PostNL and a few others only track with the postcode the parcel is going to.
    @Published var parcelPostcode: String { didSet { save("parcelPostcode", parcelPostcode) } }
    @Published var parcelPush: Bool { didSet { save("parcelPush", parcelPush ? "1" : "0") } }
    /// How many a day go to Parcel without asking. Parcel allows twenty; fifteen leaves five
    /// for the ones you file by hand.
    @Published var parcelPerDay: Int { didSet { save("parcelPerDag", String(parcelPerDay)) } }

    var parcelConfig: ParcelApp.Config {
        ParcelApp.Config(apiKey: parcelKey, postcode: parcelPostcode,
                         language: String((catalogue.preferredLocalizations.first ?? "en").prefix(2)),
                         pushConfirmation: parcelPush)
    }

    var parcelReady: Bool { parcelOn && !parcelKey.isEmpty }

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
        modelsWithoutThinking = read("zonderDenken", "").split(separator: "\n").map(String.init)
        account = read("account", "iCloud")
        mailbox = read("postvak", "INBOX")
        days = Int(read("dagen", "3")) ?? 3
        calendarName = read("agendaNaam", "Presort")
        useOwnCalendar = read("eigenAgenda", "1") == "1"
        eventCalendarId = read("agendaId", "")
        reminderListId = read("lijstId", "")
        onlyHighConfidence = read("zekerheid", "1") == "1"
        fileAutomatically = read("zetZelfIn", "0") == "1"
        leadDays = Int(read("voorsprong", "3")) ?? 3
        hasSeenWelcome = read("welkomGezien", "0") == "1"
        paperlessOn = read("paperlessAan", "0") == "1"
        paperlessAddress = read("paperlessAdres", "")
        paperlessTags = read("paperlessTags", "presort")
        paperlessCreatesCorrespondents = read("paperlessCorrespondent", "0") == "1"
        parcelOn = read("parcelAan", "0") == "1"
        parcelPostcode = read("parcelPostcode", "")
        parcelPush = read("parcelPush", "1") == "1"
        parcelPerDay = min(max(Int(read("parcelPerDag", "15")) ?? 15, 0), ParcelApp.dailyLimit)
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
