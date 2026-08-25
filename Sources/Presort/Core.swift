import Combine
import Foundation

/// Everything the app does, separated from wherever the request came from. The window and
/// the menu bar item both talk to this, which is why it no longer lives in the view: a run
/// in the background has no window at all.
@MainActor
final class Core: ObservableObject {
    let preferences = Preferences()
    let queue = Queue()
    let detectors = Detectors()
    let alarm = Alarm()

    @Published var statusLine = ""
    @Published var busy = false

    /// Driven from two places -- the first launch and the Help menu -- so it lives here
    /// rather than in the window that happens to show it.
    @Published var showWelcome = false

    private lazy var scanner = Scanner(preferences: preferences, queue: queue,
                                       detectors: detectors)
    private var calendarStore: CalendarStore?
    /// Built once and kept, so its settings can be refreshed rather than a new client made
    /// for every document.
    private lazy var paperless = Paperless(config: preferences.paperlessConfig)
    private var subscriptions = Set<AnyCancellable>()

    init() {
        // The ticker follows the setting: change it and it moves along immediately.
        preferences.$rhythmMinutes
            .removeDuplicates()
            .sink { [weak self] minutes in
                Task { @MainActor in self?.scheduleAlarm(minutes) }
            }
            .store(in: &subscriptions)
    }

    /// Once at startup: request access and wind up the ticker.
    func start() async {
        NotificationDelegate.shared.connect()
        if !preferences.hasSeenWelcome { showWelcome = true }

        if calendarStore == nil {
            let a = CalendarStore(target: calendarTarget)
            calendarStore = a
            do { try await a.askAccess() }
            catch { statusLine = error.localizedDescription }
        }
        if preferences.notificationsOn {
            await Notifier.askPermission()
        }
        scheduleAlarm(preferences.rhythmMinutes)
    }

    /// Read fresh on every write, so changing where things land in Settings takes effect
    /// at once instead of at the next launch.
    private var calendarTarget: CalendarStore.Target {
        CalendarStore.Target(
            ownName: preferences.calendarName,
            eventCalendarId: preferences.useOwnCalendar ? "" : preferences.eventCalendarId,
            reminderListId: preferences.useOwnCalendar ? "" : preferences.reminderListId)
    }

    private func scheduleAlarm(_ minutes: Int) {
        alarm.set(every: minutes) { [weak self] in
            await self?.check(automatic: true)
        }
    }

    // MARK: scanning

    func check(automatic: Bool = false) async {
        guard !busy else { return }

        // A run started by itself must not wake Mail: that would open an application you
        // had deliberately closed.
        if automatic && !Mail.isRunning {
            statusLine = t("run.mailNotRunning")
            return
        }

        busy = true
        let outcome = await scanner.check { [weak self] line in
            self?.statusLine = line
        }
        busy = false

        let auto = preferences.fileAutomatically ? await fileAutomatically(outcome.ids) : AutoFiled()
        statusLine = outcome.statusLine + auto.tail
        alarm.reschedule()

        if automatic, preferences.notificationsOn, outcome.proposed > 0 {
            Notifier.post(heading: headingForNotification(outcome, auto),
                           text: outcome.titles.prefix(3).joined(separator: " · "))
        }
    }

    /// The notification has to say what happened. "3 waiting for you" while they are
    /// already filed is not merely confusing, it is untrue.
    private func headingForNotification(_ outcome: Scanner.Outcome, _ auto: AutoFiled) -> String {
        if auto.filedCount > 0 {
            let filedCount = auto.filedCount == 1
                ? t("notify.filed.one")
                : String(format: t("notify.filed.many"), auto.filedCount)
            guard auto.stillWaiting > 0 else { return filedCount }
            return String(format: t("notify.filedAndWaiting"), filedCount, auto.stillWaiting)
        }
        return outcome.proposed == 1
            ? t("notify.waiting.one")
            : String(format: t("notify.waiting.many"), outcome.proposed)
    }

    private struct AutoFiled {
        var filedCount = 0
        var stillWaiting = 0

        var tail: String {
            guard filedCount > 0 || stillWaiting > 0 else { return "" }
            var s = filedCount == 1
                ? t("tail.filed.one")
                : String(format: t("tail.filed.many"), filedCount)
            if filedCount == 0 { s = "" }
            if stillWaiting > 0 {
                s += stillWaiting == 1
                    ? t("tail.unsure.one")
                    : String(format: t("tail.unsure.many"), stillWaiting)
            }
            return s
        }
    }

    /// Files whatever the model marked as "hoog" by itself. The rest keeps waiting: the
    /// point is that you have less to go through, not that you no longer can.
    private func fileAutomatically(_ ids: [String]) async -> AutoFiled {
        var result = AutoFiled()
        for id in ids {
            guard let v = queue.items.first(where: { $0.id == id }), v.status == .waiting else {
                continue
            }
            // No confidence given counts as not confident. Silence is not consent here.
            guard v.confidence == "hoog" else {
                result.stillWaiting += 1
                continue
            }
            await decide(v, yes: true)
            // `keur` can still fail or land on "already there"; only what was actually
            // created counts.
            if queue.items.first(where: { $0.id == id })?.status == .filed {
                result.filedCount += 1
            }
        }
        return result
    }

    // MARK: decisions

    func decide(_ v: Proposal, yes: Bool) async {
        guard yes else {
            queue.update(v.id) { $0.status = .discarded }
            return
        }
        guard let where_ = await destination(for: v) else {
            queue.update(v.id) { $0.status = .failed; $0.error = t("status.noDestination") }
            return
        }
        do {
            switch try await where_.file(v) {
            case .filed(let id):
                queue.update(v.id) { $0.status = .filed; $0.itemId = id
                                     $0.destination = where_.id }
            case .alreadyThere:
                queue.update(v.id) { $0.status = .discarded; $0.error = t("status.alreadyThere") }
            }
        } catch {
            queue.update(v.id) { $0.status = .failed; $0.error = error.localizedDescription }
            statusLine = error.localizedDescription
        }
    }

    /// Which destination a proposal belongs to, brought up to date with Settings first.
    /// One place to look, so adding a destination is not a matter of finding every `if`.
    private func destination(for v: Proposal) async -> (any Destination)? {
        switch v.category {
        case .event, .reminder:
            guard let calendarStore else { return nil }
            await calendarStore.setTarget(calendarTarget)
            await calendarStore.setLeadDays(preferences.leadDays)
            return calendarStore
        case .document:
            guard preferences.paperlessReady else { return nil }
            await paperless.setConfig(preferences.paperlessConfig)
            await paperless.setSource(Mailbox(account: preferences.account,
                                              mailbox: preferences.mailbox))
            return paperless
        case .skipped:
            return nil
        }
    }

    /// Where something went, for undoing it. Falls back to the calendar: proposals filed
    /// before there was a choice have nothing stored, and back then there was nowhere else.
    private func destination(named id: String?) -> (any Destination)? {
        switch id {
        case nil, "calendar": return calendarStore
        case "paperless": return preferences.paperlessReady ? paperless : nil
        default: return nil
        }
    }

    func undo(_ v: Proposal) async {
        guard !v.itemId.isEmpty, let where_ = destination(named: v.destination) else { return }
        do {
            try await where_.undo(v)
            queue.update(v.id) { $0.status = .discarded; $0.error = t("status.undone") }
        } catch {
            statusLine = error.localizedDescription
        }
    }
}
