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

    private lazy var scanner = Scanner(preferences: preferences, queue: queue,
                                       detectors: detectors)
    private var calendarStore: CalendarStore?
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
        guard let calendarStore else { return }
        await calendarStore.setTarget(calendarTarget)
        do {
            let id: String
            if v.category == .event {
                guard let b = v.start, let e = v.end else { return }
                if await calendarStore.hasEvent(title: v.title, start: b) {
                    queue.update(v.id) { $0.status = .discarded; $0.error = t("status.alreadyThere") }
                    return
                }
                id = try await calendarStore.makeEvent(title: v.title, start: b, end: e,
                                                   location: v.location, note: v.note)
            } else {
                id = try await calendarStore.makeReminder(
                    what: v.title, dueDate: v.dueDate, note: v.note,
                    leadDays: preferences.leadDays)
            }
            queue.update(v.id) { $0.status = .filed; $0.itemId = id }
        } catch {
            queue.update(v.id) { $0.status = .failed; $0.error = error.localizedDescription }
            statusLine = error.localizedDescription
        }
    }

    func undo(_ v: Proposal) async {
        guard let calendarStore, !v.itemId.isEmpty else { return }
        do {
            if v.category == .event { try await calendarStore.remove(eventId: v.itemId) }
            else { try await calendarStore.remove(reminderId: v.itemId) }
            queue.update(v.id) { $0.status = .discarded; $0.error = t("status.undone") }
        } catch {
            statusLine = error.localizedDescription
        }
    }
}
