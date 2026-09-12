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

    /// A sentence when the model is not giving usable answers. Shown above the queue until a
    /// run or a check says otherwise: without a working model nothing is found at all, and a
    /// status line saying "3 did not work" is easy to read past.
    @Published var modelProblem: String?

    private lazy var scanner = Scanner(preferences: preferences, queue: queue,
                                       detectors: detectors)
    private var calendarStore: CalendarStore?
    /// Built once and kept, so its settings can be refreshed rather than a new client made
    /// for every document.
    private lazy var paperless = Paperless(config: preferences.paperlessConfig)
    private lazy var parcel = ParcelApp(config: preferences.parcelConfig)
    /// When Parcel was last asked for delivery days. That list allows twenty asks an hour.
    private var parcelsAskedAt: Date?
    private var subscriptions = Set<AnyCancellable>()

    init() {
        // The ticker follows the setting: change it and it moves along immediately.
        preferences.$rhythmMinutes
            .removeDuplicates()
            .sink { [weak self] minutes in
                Task { @MainActor in self?.scheduleAlarm(minutes) }
            }
            .store(in: &subscriptions)

        // Another model, address or key deserves a fresh verdict. Debounced: these change on
        // every keystroke, and every check is a request to somebody's machine.
        Publishers.CombineLatest3(preferences.$model, preferences.$endpoint, preferences.$key)
            .dropFirst()
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.checkModel() }
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
        await checkModel()
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

        let auto = await fileAutomatically(outcome.ids)
        statusLine = outcome.statusLine + auto.tail
        // One usable answer is proof enough. Nothing but failures from the model is worth a
        // closer look, and a notification when nobody is watching the window.
        if outcome.checked > 0 {
            modelProblem = nil
        } else if outcome.modelFailed > 0 {
            await checkModel(notify: automatic)
        }
        await followParcels()
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

    /// Files whatever the model marked as "hoog" by itself, when that is switched on. The rest
    /// keeps waiting: the point is that you have less to go through, not that you no longer
    /// can. Parcels have a rule of their own, see `mayFileParcelByItself`.
    private func fileAutomatically(_ ids: [String]) async -> AutoFiled {
        var result = AutoFiled()
        for id in ids {
            guard let v = queue.items.first(where: { $0.id == id }), v.status == .waiting else {
                continue
            }
            if v.category == .parcel {
                guard await mayFileParcelByItself(v) else { continue }
            } else {
                guard preferences.fileAutomatically else { continue }
                // No confidence given counts as not confident. Silence is not consent here.
                guard v.confidence == "hoog" else {
                    result.stillWaiting += 1
                    continue
                }
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

    // MARK: the model

    /// Asks the model one made-up question and takes the verdict. Runs at start, when the
    /// model changes, and after a run in which no answer could be used.
    func checkModel(notify: Bool = false) async {
        guard preferences.isConfigured else {
            modelProblem = nil
            return
        }
        let name = preferences.model
        let client = ModelClient(endpoint: preferences.endpoint, key: preferences.key, model: name)
        adopt(await client.check(startingWith: preferences.thinkingOff), for: name, notify: notify)
    }

    /// Takes a verdict about the model in use, from a check here or a test in Settings. A
    /// model that only works with thinking switched off gets that switched on: the check just
    /// showed that it helps.
    func adopt(_ result: ModelClient.Check, for name: String, notify: Bool = false) {
        guard name == preferences.model else { return }
        switch result.health {
        case .works:
            modelProblem = nil
        case .needsThinkingOff:
            preferences.setThinkingOff(true, for: name)
            modelProblem = nil
        default:
            let text = String(format: t("modelcheck.problem.body"), name, result.sentence)
            if notify, modelProblem != text, preferences.notificationsOn {
                Notifier.post(heading: t("modelcheck.problem.title"), text: text)
            }
            modelProblem = text
        }
    }

    // MARK: parcels

    /// The first parcels of the day go to Parcel without asking -- fifteen by default, which
    /// leaves five of Parcel's twenty for the button. Only when nothing about it needs you:
    /// the model was sure, and the carrier is one Parcel knows. Without Parcel a parcel is
    /// only a reminder, and that follows the general setting.
    private func mayFileParcelByItself(_ v: Proposal) async -> Bool {
        guard v.confidence == "hoog" else { return false }
        await preferences.loadParcelKey()
        guard preferences.parcelReady else {
            return preferences.fileAutomatically && v.dueDate != nil
        }
        guard ParcelQuota().used() < preferences.parcelPerDay else { return false }
        let carriers = await ParcelCarriers.shared.all()
        return ParcelApp.carrier(for: v, among: carriers, region: ParcelApp.macRegion) != nil
    }

    /// Gives a parcel filed without a day its reminder once Parcel knows the day, and moves a
    /// reminder along when the carrier changes it. Asks Parcel at most once an hour, and only
    /// while a parcel is still on its way.
    func followParcels() async {
        let month = Date().addingTimeInterval(-30 * 86400)
        let open = queue.items.filter {
            $0.category == .parcel && $0.status == .filed && $0.time > month
            && $0.trackingNumber != nil
            && ($0.dueDate.map(ParcelFiling.stillAhead) ?? true)
        }
        guard !open.isEmpty else { return }
        if let at = parcelsAskedAt, Date().timeIntervalSince(at) < 3600 { return }
        await preferences.loadParcelKey()
        guard preferences.parcelReady, let calendarStore else { return }
        parcelsAskedAt = Date()
        await parcel.setConfig(preferences.parcelConfig)
        await calendarStore.setTarget(calendarTarget)
        guard let known = try? await parcel.deliveries(maxAge: 0) else { return }
        let carriers = await ParcelCarriers.shared.all()

        for v in open {
            guard let d = known.first(where: { ParcelApp.same($0.trackingNumber, v.trackingNumber ?? "") }),
                  d.statusCode != 0, let day = d.expected, ParcelFiling.stillAhead(day)
            else { continue }
            if let reminder = ParcelFiling.reminderId(in: v.itemId) {
                if let was = v.dueDate, abs(was.timeIntervalSince(day)) < 60 { continue }
                if (try? await calendarStore.moveReminder(reminder, to: day)) == true {
                    queue.update(v.id) { $0.dueDate = day }
                }
            } else {
                let name = carriers.first { $0.code == d.carrierCode }?.name ?? v.carrier ?? ""
                if let id = try? await calendarStore.makeParcelReminder(
                    title: ParcelFiling.title(v), arriving: day,
                    note: ParcelFiling.note(v, carrier: name)) {
                    queue.update(v.id) { $0.dueDate = day; $0.itemId += " reminder:" + id }
                }
            }
        }
    }

    // MARK: decisions

    func decide(_ v: Proposal, yes: Bool) async {
        guard yes else {
            queue.update(v.id) { $0.status = .discarded }
            return
        }
        guard let where_ = await destination(for: v) else {
            queue.update(v.id) { $0.status = .failed; $0.error = Proposal.Note.noDestination }
            return
        }
        do {
            switch try await where_.file(v) {
            case .filed(let id):
                queue.update(v.id) { $0.status = .filed; $0.itemId = id
                                     $0.destination = where_.id }
            case .alreadyThere:
                queue.update(v.id) { $0.status = .discarded; $0.error = Proposal.Note.alreadyThere }
            }
        } catch {
            // Something you can put right -- a carrier to pick, a postcode, a new day -- leaves
            // it waiting. Failed would leave no button to try again with.
            if let problem = error as? ParcelApp.Problem, problem.keepsWaiting {
                statusLine = error.localizedDescription
                return
            }
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
            await preferences.loadPaperlessToken()
            guard preferences.paperlessReady else { return nil }
            await paperless.setConfig(preferences.paperlessConfig)
            await paperless.setSource(Mailbox(account: preferences.account,
                                              mailbox: preferences.mailbox))
            return paperless
        case .parcel:
            // Parcel when it is connected, the reminder when the calendar is; either will do.
            await preferences.loadParcelKey()
            var app: ParcelApp?
            if preferences.parcelReady {
                await parcel.setConfig(preferences.parcelConfig)
                app = parcel
            }
            if let calendarStore { await calendarStore.setTarget(calendarTarget) }
            guard app != nil || calendarStore != nil else { return nil }
            return ParcelFiling(parcel: app, calendar: calendarStore)
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
        case "parcel": return ParcelFiling(parcel: nil, calendar: calendarStore)
        default: return nil
        }
    }

    func undo(_ v: Proposal) async {
        guard !v.itemId.isEmpty, let where_ = destination(named: v.destination) else { return }
        do {
            try await where_.undo(v)
            queue.update(v.id) { $0.status = .discarded; $0.error = Proposal.Note.undone }
        } catch {
            statusLine = error.localizedDescription
        }
    }
}
