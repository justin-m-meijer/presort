import Foundation

/// Hands tracking numbers to Parcel (parcelapp.net), the delivery tracker.
///
/// Parcel's API is small and strict: one delivery per request, twenty additions a day with
/// the refused ones counted, and only for Premium. Most of this file follows from that
/// number. Nothing is sent that could have been checked first: the tracking number must be
/// in the mail, the carrier must be one Parcel knows, a carrier that wants a postcode gets
/// one, and a number Parcel already tracks is not added a second time.
///
/// Parcel has no call to remove a delivery, so nothing sent here can be taken back.
actor ParcelApp {
    struct Config: Equatable {
        var apiKey = ""
        /// Only sent to carriers that ask for it.
        var postcode = ""
        /// Two letters. Parcel shows a carrier's updates in it where the carrier offers that.
        var language = "en"
        var pushConfirmation = true
    }

    /// Parcel's own limit on additions per day.
    static let dailyLimit = 20

    struct Carrier: Hashable, Identifiable, Sendable {
        let code: String
        let name: String
        /// Parcel's `extra_required`. For the carriers this app meets, that is the postcode.
        let needsExtra: Bool
        var id: String { code }
    }

    /// One row of what Parcel is tracking.
    struct Delivery: Sendable {
        let trackingNumber: String
        let carrierCode: String
        /// 0 is delivered; see Parcel's documentation for the rest.
        let statusCode: Int
        let expected: Date?
    }

    enum Problem: LocalizedError {
        case notConfigured
        case http(Int, String)
        case rejected(String)
        case noTrackingNumber
        case noCarrier
        case needsPostcode(String)
        case dailyLimit(Int)
        case nothingToDo

        var errorDescription: String? {
            switch self {
            case .notConfigured: return t("parcel.error.notConfigured")
            case .http(let code, let body): return String(format: t("parcel.error.http"), code, body)
            case .rejected(let why): return String(format: t("parcel.error.rejected"), why)
            case .noTrackingNumber: return t("parcel.error.noTrackingNumber")
            case .noCarrier: return t("parcel.error.noCarrier")
            case .needsPostcode(let carrier):
                return String(format: t("parcel.error.needsPostcode"), carrier, t("tab.connections"))
            case .dailyLimit(let n): return String(format: t("parcel.error.dailyLimit"), n)
            case .nothingToDo: return t("parcel.error.nothingToDo")
            }
        }

        /// What can be put right from the card or in Settings. Those leave a proposal waiting
        /// rather than failed: a failed proposal has no button left to try again with.
        var keepsWaiting: Bool {
            switch self {
            case .notConfigured, .noCarrier, .needsPostcode, .dailyLimit: return true
            default: return false
            }
        }
    }

    private var config: Config
    private var recent: (at: Date, deliveries: [Delivery])?

    init(config: Config) { self.config = config }

    func setConfig(_ c: Config) {
        if c.apiKey != config.apiKey { recent = nil }
        config = c
    }

    // MARK: talking to it

    private static let base = "https://api.parcel.app/external/"

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard !config.apiKey.isEmpty else { throw Problem.notConfigured }
        var r = URLRequest(url: URL(string: ParcelApp.base + path)!)
        r.httpMethod = method
        r.timeoutInterval = 30
        r.setValue(config.apiKey, forHTTPHeaderField: "api-key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    /// Parcel says no with `"success": false` and a sentence, so that is checked as well as
    /// the status code, and the sentence is passed on as it stands.
    private func send(_ r: URLRequest) async throws -> [String: Any] {
        let (data, answer) = try await URLSession.shared.data(for: r)
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let body = String(data: data, encoding: .utf8) ?? ""
        let said = root?["error_message"] as? String ?? String(body.prefix(200))
        if let h = answer as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw Problem.http(h.statusCode, said)
        }
        guard let root, root["success"] as? Bool == true else { throw Problem.rejected(said) }
        return root
    }

    /// What Parcel tracks now and tracked recently. This call has a limit of its own, twenty
    /// an hour, so an answer is kept for a while: filing a batch asks once.
    func deliveries(maxAge: TimeInterval = 600) async throws -> [Delivery] {
        if let recent, Date().timeIntervalSince(recent.at) < maxAge { return recent.deliveries }
        let root = try await send(try request("deliveries/?filter_mode=recent"))
        let list = (root["deliveries"] as? [[String: Any]] ?? []).compactMap(ParcelApp.delivery(from:))
        recent = (Date(), list)
        return list
    }

    /// Does the key work? Asked of the list rather than by adding something: the list has its
    /// own hourly limit and leaves the twenty a day alone.
    func check() async throws -> String {
        let tracking = try await deliveries(maxAge: 0).filter { $0.statusCode != 0 }.count
        return String(format: t("parcel.check.ok"), tracking, ParcelQuota().used(), ParcelApp.dailyLimit)
    }

    // MARK: adding

    /// Adds one delivery. Counted before it goes out, because Parcel counts it either way.
    func add(number: String, carrier: Carrier, description: String) async throws {
        let quota = ParcelQuota()
        guard quota.used() < ParcelApp.dailyLimit else { throw Problem.dailyLimit(ParcelApp.dailyLimit) }
        let postcode = config.postcode.replacingOccurrences(of: " ", with: "").uppercased()
        if carrier.needsExtra && postcode.isEmpty { throw Problem.needsPostcode(carrier.name) }

        var body: [String: Any] = [
            "tracking_number": number,
            "carrier_code": carrier.code,
            "description": String(description.prefix(100)),
            "language": config.language,
            "send_push_confirmation": config.pushConfirmation,
        ]
        // Where you live goes only to a carrier that cannot track without it.
        if carrier.needsExtra { body["postcode"] = postcode }

        var r = try request("add-delivery/", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        quota.record()
        _ = try await send(r)
    }

    /// The whole route for a proposal: check what can be checked, skip what Parcel already
    /// has, and only then spend a request. Asking for the list first costs nothing against
    /// the daily limit; if that ask fails, adding goes ahead rather than stopping on it.
    func add(_ proposal: Proposal, carriers: [Carrier], region: String?) async throws -> Filing {
        guard let number = proposal.trackingNumber, !number.isEmpty else { throw Problem.noTrackingNumber }
        guard let carrier = ParcelApp.carrier(for: proposal, among: carriers, region: region) else {
            throw Problem.noCarrier
        }
        let known = (try? await deliveries()) ?? []
        if known.contains(where: { ParcelApp.same($0.trackingNumber, number) }) {
            return .alreadyThere
        }
        try await add(number: number, carrier: carrier, description: proposal.title)
        recent = nil
        return .filed("parcel:\(carrier.code):\(number)")
    }
}

// MARK: what can be decided without asking Parcel

extension ParcelApp {
    /// "3S ABCD 1234-567" and "3sabcd1234567" are the same parcel: mail breaks a long number
    /// up for reading, Parcel wants it whole. Only ASCII letters and digits survive.
    static func normalized(_ s: String) -> String {
        s.uppercased().filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// The number as Parcel should get it: capitals, no spaces, dashes kept. Some numbers carry
    /// their dashes -- an Amazon order number sits in Parcel's own list as 304-…-… -- and
    /// Parcel checks the format, so they stay. `normalized` is for comparing.
    static func cleaned(_ s: String) -> String {
        s.uppercased()
            .filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Long enough, and with a digit in it. Carriers differ too much for anything stricter;
    /// this only throws out what no carrier uses, and Parcel checks the format itself.
    static func plausibleTrackingNumber(_ n: String) -> Bool {
        let bare = normalized(n)
        return (8...40).contains(bare.count) && bare.contains { ("0"..."9").contains($0) } && n == cleaned(n)
    }

    /// Is the number actually in the mail? A model can produce something that looks like a
    /// tracking number; it cannot make one appear in the text.
    static func appears(_ number: String, in text: String) -> Bool {
        let bare = normalized(number)
        return !bare.isEmpty && normalized(text).contains(bare)
    }

    /// The same parcel, however either side wrote the number.
    static func same(_ a: String, _ b: String) -> Bool {
        let bare = normalized(a)
        return !bare.isEmpty && bare == normalized(b)
    }

    /// Which of Parcel's carriers the mail means. Matched, never guessed: when a name fits
    /// several and nothing decides between them, the answer is nil and the card asks. A wrong
    /// carrier costs one of the twenty requests and tracks nothing.
    ///
    /// `region` is the English name of the country this Mac is set to. It is what tells DHL
    /// Netherlands apart from DHL Express when a mail just says DHL.
    static func match(_ said: String, among carriers: [Carrier], region: String?) -> Carrier? {
        let want = simple(said)
        guard !want.isEmpty else { return nil }
        let live = carriers.filter { !$0.name.localizedCaseInsensitiveContains("deprecated") }
        if let exact = live.first(where: { simple($0.name) == want }) { return exact }

        // "PostNL Pakketservice" is PostNL. "DHL" is any of eight, and "DHL eCommerce" is not
        // a name Parcel uses at all, so the first word has to do.
        var candidates = live.filter {
            let name = simple($0.name)
            return name.hasPrefix(want + " ") || want.hasPrefix(name + " ")
        }
        if candidates.isEmpty {
            let first = want.split(separator: " ").first
            candidates = live.filter { simple($0.name).split(separator: " ").first == first }
        }
        if candidates.count == 1 { return candidates[0] }
        if let region, !region.isEmpty {
            let local = candidates.filter { $0.name.localizedCaseInsensitiveContains(region) }
            if local.count == 1 { return local[0] }
        }
        return nil
    }

    private static func simple(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
    }

    /// The carrier picked on the card, or else the one the mail names.
    static func carrier(for proposal: Proposal, among list: [Carrier], region: String?) -> Carrier? {
        if let code = proposal.carrierCode, let picked = list.first(where: { $0.code == code }) {
            return picked
        }
        return match(proposal.carrier ?? "", among: list, region: region)
    }

    /// The English name of the country this Mac is set to: "Netherlands".
    static var macRegion: String? {
        guard let code = Locale.current.region?.identifier else { return nil }
        return Locale(identifier: "en_US").localizedString(forRegionCode: code)
    }

    /// Parcel's `supported_carriers.json`: code → name, plus whether it wants more than a number.
    static func carriers(from data: Data) -> [Carrier]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return root.compactMap { code, value -> Carrier? in
            guard let row = value as? [String: Any], let name = row["name"] as? String else { return nil }
            let extra = (row["extra_required"] as? NSNumber)?.intValue ?? 0
            return Carrier(code: code, name: name, needsExtra: extra != 0)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func delivery(from row: [String: Any]) -> Delivery? {
        guard let number = row["tracking_number"] as? String else { return nil }
        var expected: Date?
        if let stamp = (row["timestamp_expected"] as? NSNumber)?.doubleValue {
            expected = Date(timeIntervalSince1970: stamp)
        } else if let day = row["date_expected"] as? String {
            // A day without a time: nine in the morning, like any other date without one.
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            expected = f.date(from: String(day.prefix(10))).flatMap {
                Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: $0)
            }
        }
        return Delivery(trackingNumber: number,
                        carrierCode: row["carrier_code"] as? String ?? "",
                        statusCode: (row["status_code"] as? NSNumber)?.intValue ?? -1,
                        expected: expected)
    }
}

/// Parcel's twenty a day, counted on this Mac so the app stops before Parcel refuses, and so
/// the parcels that go in by themselves can leave room for yours. Counted per day in the
/// Mac's own time zone; if Parcel's day turns at another hour this is off by a few requests
/// at worst, and Parcel's own refusal is still there behind it.
struct ParcelQuota {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    func used(on date: Date = Date()) -> Int {
        defaults.string(forKey: "parcelDag") == ParcelQuota.day(date)
            ? defaults.integer(forKey: "parcelAantal") : 0
    }

    func record(on date: Date = Date()) {
        let count = used(on: date) + 1
        defaults.set(ParcelQuota.day(date), forKey: "parcelDag")
        defaults.set(count, forKey: "parcelAantal")
    }
}

/// Parcel's list of carriers. It needs no key and counts against nothing, but it is three
/// hundred names that barely change, so it is fetched once a week and kept on disk -- which
/// also keeps the card's picker filled when the network is not there.
actor ParcelCarriers {
    static let shared = ParcelCarriers()

    private static let source = URL(string: "https://api.parcel.app/external/supported_carriers.json")!
    private var list: [ParcelApp.Carrier] = []
    private var fetched: Date?
    private var tried: Date?
    private let file: URL

    init(folder: URL? = nil) {
        let folder = folder ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Presort", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("parcel-carriers.json")
    }

    func all() async -> [ParcelApp.Carrier] {
        if list.isEmpty, let data = try? Data(contentsOf: file), let stored = ParcelApp.carriers(from: data) {
            list = stored
            fetched = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        }
        if let fetched, Date().timeIntervalSince(fetched) < 7 * 86400, !list.isEmpty { return list }
        // Offline, every card would try again the moment it appears. Once in ten minutes will do.
        if let tried, Date().timeIntervalSince(tried) < 600 { return list }
        tried = Date()
        if let answer = try? await URLSession.shared.data(from: ParcelCarriers.source),
           let fresh = ParcelApp.carriers(from: answer.0), !fresh.isEmpty {
            list = fresh
            fetched = Date()
            try? answer.0.write(to: file, options: .atomic)
        }
        return list
    }
}
