import EventKit
import Foundation

/// Writes into a calendar and a reminder list of its own by default: what the app proposes
/// stays separate, is easy to look over, and undoing it can never touch something you put
/// there yourself. A user who would rather have it land between their own entries can say
/// so -- `Target` is what carries that decision down here.
actor CalendarStore {
    private let store = EKEventStore()
    private var target: Target

    /// Where the app writes. An empty identifier means "my own", so the default costs no
    /// configuration and a calendar that disappears falls back to something that exists.
    struct Target: Equatable {
        var ownName: String
        var eventCalendarId: String = ""
        var reminderListId: String = ""
    }

    init(target: Target) { self.target = target }

    /// Called before every write, so a change in Settings takes effect without a restart.
    func setTarget(_ t: Target) { target = t }

    /// What the user can pick from. Read-only calendars -- subscribed ones, holidays -- are
    /// left out: offering them means offering a write that will fail.
    struct Choice: Identifiable, Hashable {
        let id: String
        let title: String
        let account: String
    }

    private func choices(for type: EKEntityType) -> [Choice] {
        store.calendars(for: type)
            .filter(\.allowsContentModifications)
            .map { Choice(id: $0.calendarIdentifier, title: $0.title,
                          account: $0.source?.title ?? "") }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    func writableCalendars() -> [Choice] { store.reset(); return choices(for: .event) }
    func writableLists() -> [Choice] { store.reset(); return choices(for: .reminder) }

    enum Problem: LocalizedError {
        case noAccess(String)
        case noSource
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAccess(let what):
                return String(format: t("calendar.error.noAccess"), what)
            case .noSource: return t("calendar.error.noSource")
            case .saveFailed(let m): return String(format: t("calendar.error.saveFailed"), m)
            }
        }
    }

    func askAccess() async throws {
        if try await store.requestFullAccessToEvents() == false {
            throw Problem.noAccess(t("calendar.permission.calendar"))
        }
        if try await store.requestFullAccessToReminders() == false {
            throw Problem.noAccess(t("calendar.permission.reminders"))
        }
    }

    /// The calendar to write events into: the one the user chose, or our own.
    private func eventCalendar() throws -> EKCalendar {
        // A chosen calendar can be deleted or turned read-only behind our back. Falling back
        // to our own is better than refusing to file: the entry still lands somewhere the
        // user can find, and the note in it says where it came from.
        if !target.eventCalendarId.isEmpty,
           let chosen = store.calendar(withIdentifier: target.eventCalendarId),
           chosen.allowsContentModifications {
            return chosen
        }
        if let existing = store.calendars(for: .event).first(where: { $0.title == target.ownName }) {
            return existing
        }
        // Pick the source by what it demonstrably supports rather than by its name: an
        // account may handle calendars but not reminders, and both are often called "iCloud".
        guard let source = store.sources.first(where: { !$0.calendars(for: .event).isEmpty }) else {
            throw Problem.noSource
        }
        let k = EKCalendar(for: .event, eventStore: store)
        k.title = target.ownName
        k.source = source
        try store.saveCalendar(k, commit: true)
        return k
    }

    /// The same for reminders. Chosen separately: wanting appointments between your own but
    /// tasks in a list of their own is a perfectly sensible combination.
    private func reminderList() throws -> EKCalendar {
        if !target.reminderListId.isEmpty,
           let chosen = store.calendar(withIdentifier: target.reminderListId),
           chosen.allowsContentModifications {
            return chosen
        }
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == target.ownName }) {
            return existing
        }
        guard let source = store.sources.first(where: { !$0.calendars(for: .reminder).isEmpty }) else {
            throw Problem.noSource
        }
        let k = EKCalendar(for: .reminder, eventStore: store)
        k.title = target.ownName
        k.source = source
        try store.saveCalendar(k, commit: true)
        return k
    }

    func makeEvent(title: String, start: Date, end: Date,
                      location: String, note: String) throws -> String {
        store.reset()
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = start
        e.endDate = end
        if !location.isEmpty { e.location = location }
        e.notes = note
        e.calendar = try eventCalendar()
        do { try store.save(e, span: .thisEvent, commit: true) }
        catch { throw Problem.saveFailed(error.localizedDescription) }
        return e.eventIdentifier ?? ""
    }

    func makeReminder(what: String, dueDate: Date?, note: String,
                         leadDays: Int = 0) throws -> String {
        store.reset()
        let r = EKReminder(eventStore: store)
        r.title = what
        r.notes = note
        r.calendar = try reminderList()
        if let d = dueDate {
            // The deadline stays the deadline -- that is what shows in the list and what
            // you want to see. The alert comes earlier: on the final day, getting a parcel
            // back is usually no longer possible.
            r.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: d)
            // If that moment has already passed, `seintje` returns nil and the deadline
            // itself is all that is left. The window shows the same calculation, so what it
            // says is what happens here.
            if let wake = Dates.alert(dueDate: d, leadDays: leadDays) {
                r.addAlarm(EKAlarm(absoluteDate: wake))
            }
        }
        do { try store.save(r, commit: true) }
        catch { throw Problem.saveFailed(error.localizedDescription) }
        return r.calendarItemIdentifier
    }

    /// Does something with this title already exist around this time? Guards against
    /// duplicate work if the saved state is ever lost.
    func hasEvent(title: String, start: Date) -> Bool {
        store.reset()
        guard let k = try? eventCalendar() else { return false }
        let from = start.addingTimeInterval(-3600)
        let until = start.addingTimeInterval(3600)
        let p = store.predicateForEvents(withStart: from, end: until, calendars: [k])
        return store.events(matching: p).contains { $0.title == title }
    }

    func remove(eventId: String) throws {
        store.reset()
        guard let e = store.event(withIdentifier: eventId) else { return }
        try store.remove(e, span: .thisEvent, commit: true)
    }

    func remove(reminderId: String) throws {
        store.reset()
        guard let r = store.calendarItem(withIdentifier: reminderId) as? EKReminder else { return }
        try store.remove(r, commit: true)
    }
}
