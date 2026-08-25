import Foundation

/// The loop: fetch mail, put it to the model, check the answer, and turn it into a
/// proposal. Nothing is created here -- that happens only when the user presses approve
/// in the window.
@MainActor
final class Scanner: ObservableObject {
    @Published var busy = false
    @Published var lastStatusLine = ""

    private let preferences: Preferences
    private let queue: Queue
    private let detectors: Detectors

    init(preferences: Preferences, queue: Queue, detectors: Detectors) {
        self.preferences = preferences
        self.queue = queue
        self.detectors = detectors
    }

    /// What a run produced. The caller decides what happens with it: the window puts it
    /// in the status bar, a background run turns it into a notification.
    struct Outcome {
        var checked = 0
        var proposed = 0
        /// Messages where Mail or the model dropped out. Those stay open for the next
        /// run, so they do not count as checked.
        var failed = 0
        var titles: [String] = []
        /// The proposals from this run, so the caller can handle them without guessing
        /// which ones are new.
        var ids: [String] = []
        var statusLine = ""
    }

    /// `voortgang` is called during the run with the line that belongs in the status
    /// bar. Without that hand-off you only see the outcome afterwards.
    func check(progress: (String) -> Void = { _ in }) async -> Outcome {
        var outcome = Outcome()
        guard !busy else { return outcome }
        guard preferences.isConfigured else {
            outcome.statusLine = t("scan.notConfigured")
            lastStatusLine = outcome.statusLine
            return outcome
        }
        let points = detectors.active
        guard !points.isEmpty else {
            outcome.statusLine = t("scan.nothingEnabled")
            lastStatusLine = outcome.statusLine
            return outcome
        }

        busy = true
        defer { busy = false }

        let mailbox = Mailbox(account: preferences.account, mailbox: preferences.mailbox)
        let client = ModelClient(endpoint: preferences.endpoint,
                                 key: preferences.key,
                                 model: preferences.model)

        progress(String(format: t("scan.fetching"), preferences.mailbox))

        let messages: [Mailbox.Message]
        do {
            messages = try mailbox.recent(days: preferences.days, limit: 40)
        } catch {
            outcome.statusLine = error.localizedDescription
            lastStatusLine = outcome.statusLine
            return outcome
        }

        let new = messages.filter { !queue.isSeen($0.id) }
        guard !new.isEmpty else {
            outcome.statusLine = String(format: t("scan.nothingNew"), preferences.mailbox)
            lastStatusLine = outcome.statusLine
            return outcome
        }

        var proposed = 0
        for b in new.prefix(15) {
            progress(String(format: t("scan.working"), String(b.subject.prefix(40))))

            // A message only counts as seen once it has been judged: either a proposal
            // came out, or it was deliberately skipped. If Mail or the model drops out it
            // stays open -- otherwise the message vanishes quietly and nobody ever looks
            // at it again.
            let text: String
            do {
                text = try mailbox.content(from: b.id)
            } catch {
                outcome.failed += 1
                continue
            }

            guard !text.isEmpty else {
                // Read fine, there was simply nothing in it. That is a judgement.
                noteSkipped(b, t("skip.noContent"))
                queue.markSeen(b.id)
                outcome.checked += 1
                continue
            }

            // The frame around the message. It is part of the prompt, so it follows the
            // app language: an English frame around Dutch keys is what made the model
            // answer in the wrong language before.
            let frame = """
            \(String(format: t("frame.today"), Dates.today()))
            \(t("frame.sender")) \(b.sender)
            \(t("frame.subject")) \(b.subject)

            \(t("frame.untrusted"))
            \(text)
            \(t("frame.end"))
            """

            // Every enabled point is one question, in order, until something hits. A
            // message yields at most one proposal: two reminders out of the same mail are
            // nearly always the same thing said twice. A failure from the model is not a
            // judgement, so nothing is marked after one.
            var proposal: Proposal?
            // Unreadable JSON is as much a non-judgement as a network failure: only once
            // at least one answer could be read do we know anything.
            var understood = false
            do {
                for point in points {
                    let answer = try await client.ask(system: point.systemText,
                                                          user: frame)
                    guard let o = ModelClient.jsonFrom(answer) else { continue }
                    understood = true
                    proposal = point.kind == .event
                        ? makeEventProposal(o, b, point)
                        : makeTaskProposal(o, b, point)
                    if proposal != nil { break }
                }
            } catch {
                outcome.failed += 1
                continue
            }

            guard understood else {
                outcome.failed += 1
                continue
            }

            if let v = proposal {
                queue.add(v)
                proposed += 1
                outcome.titles.append(v.title)
                outcome.ids.append(v.id)
            } else {
                noteSkipped(b, points.count == 1
                    ? String(format: t("skip.noneOfOne"), points[0].name.lowercased())
                    : String(format: t("skip.noneOfMany"), points.count))
            }
            queue.markSeen(b.id)
            outcome.checked += 1
        }

        outcome.proposed = proposed
        let tail = outcome.failed == 0
            ? ""
            : String(format: t("scan.failedTail"), outcome.failed)
        outcome.statusLine = (proposed == 0
            ? String(format: t("scan.nothingFound"), outcome.checked)
            : String(format: t("scan.found"), proposed, outcome.checked)) + tail
        lastStatusLine = outcome.statusLine
        return outcome
    }

    // MARK: checking the answer

    private func confidence(_ o: [String: Any]) -> String? {
        (o["zekerheid"] as? String)?.lowercased()
    }

    private func confidentEnough(_ o: [String: Any]) -> Bool {
        guard preferences.onlyHighConfidence else { return true }
        return (o["zekerheid"] as? String)?.lowercased() == "hoog"
    }

    private func makeEventProposal(_ o: [String: Any], _ b: Mailbox.Message,
                                      _ point: Detector) -> Proposal? {
        guard (o["gevonden"] as? Bool) == true, confidentEnough(o) else { return nil }
        let title = (o["titel"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard title.count >= 2, title.count <= 120,
              let start = Dates.read(o["begin"] as? String),
              Dates.plausible(start) else { return nil }
        let end = Dates.read(o["eind"] as? String) ?? start.addingTimeInterval(3600)
        guard end > start, end.timeIntervalSince(start) < 60 * 60 * 48 else { return nil }

        return Proposal(category: .event, sender: b.sender, subject: b.subject,
                        title: title, start: start, end: end,
                        location: String((o["locatie"] as? String ?? "").prefix(200)),
                        note: note(b), detector: point.name, confidence: confidence(o))
    }

    private func makeTaskProposal(_ o: [String: Any], _ b: Mailbox.Message,
                                   _ point: Detector) -> Proposal? {
        guard (o["gevonden"] as? Bool) == true, confidentEnough(o) else { return nil }
        let what = (o["wat"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard what.count >= 4, what.count <= 200 else { return nil }
        let dueDate = Dates.read(o["uiterlijk"] as? String)
        if let u = dueDate, !Dates.plausible(u) { return nil }

        let amount = String((o["bedrag"] as? String ?? "").prefix(40))
        return Proposal(category: .reminder, sender: b.sender, subject: b.subject,
                        title: what, dueDate: dueDate, amount: amount,
                        note: note(b) + (amount.isEmpty ? "" : String(format: t("note.amount"), amount)),
                        detector: point.name, confidence: confidence(o))
    }

    private func note(_ b: Mailbox.Message) -> String {
        String(format: t("note.detected"), b.sender, b.subject)
    }

    private func noteSkipped(_ b: Mailbox.Message, _ reason: String) {
        queue.add(Proposal(category: .skipped, sender: b.sender,
                                  subject: b.subject, reason: reason))
    }
}

/// The locale the dates on screen follow. Deliberately not `Locale.current`: a Mac set to
/// Dutch running the app in English would otherwise put Dutch month names next to English
/// labels. It follows the language the app is actually showing.
let appLocale = Locale(identifier: catalogue.preferredLocalizations.first ?? "en")

enum Dates {
    static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// "2026-09-04". What paperless wants for a document's date, and unambiguous
    /// everywhere else too.
    static func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func read(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        for pattern in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.dateFormat = pattern
            f.locale = Locale(identifier: "en_US_POSIX")
            if var d = f.date(from: s) {
                if pattern == "yyyy-MM-dd" {
                    d = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d
                }
                return d
            }
        }
        return nil
    }

    /// Between roughly a month back and a year ahead. Anything outside that is invented.
    static func plausible(_ d: Date) -> Bool {
        d > Date().addingTimeInterval(-86400 * 31) && d < Date().addingTimeInterval(86400 * 400)
    }

    static func short(_ d: Date?) -> String {
        guard let d else { return t("date.none") }
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = "EEE d MMM, HH:mm"
        return f.string(from: d)
    }

    /// When the alert fires for a deadline, or nil if there is none. Both the card and
    /// `Agenda.maakHerinnering` use this: if those two did their own arithmetic, the
    /// window would promise something other than what happens.
    static func alert(dueDate: Date?, leadDays: Int) -> Date? {
        guard let d = dueDate, leadDays > 0 else { return nil }
        let wake = d.addingTimeInterval(-Double(leadDays) * 86400)
        return wake > Date() ? wake : nil
    }

    /// "Fri 4 Sep 2026, 09:00"
    static func long(_ d: Date) -> String {
        kind("EEE d MMM yyyy, HH:mm").string(from: d)
    }

    /// "Fri 4 Sep 2026"
    static func longDay(_ d: Date) -> String {
        kind("EEE d MMM yyyy").string(from: d)
    }

    /// Two moments; the day appears only once when it is the same day.
    static func spanText(_ start: Date?, _ end: Date?) -> String {
        guard let start else { return t("date.none") }
        guard let end else { return long(start) }
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return long(start) + " – " + kind("HH:mm").string(from: end)
        }
        return long(start) + " – " + long(end)
    }

    private static func kind(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = pattern
        return f
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func shortDay(_ d: Date?) -> String {
        guard let d else { return t("date.none") }
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = "EEE d MMMM"
        return f.string(from: d)
    }
}
