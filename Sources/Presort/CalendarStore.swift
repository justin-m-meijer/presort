import EventKit
import Foundation

/// Writes only into a calendar and a reminder list of its own. The user's existing
/// calendars are read but never touched: what the app proposes stays separate, and
/// dragging it into a real calendar is how the user accepts it.
actor CalendarStore {
    private let store = EKEventStore()
    private let name: String

    init(name: String) { self.name = name }

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

    /// Our own calendar, created if it does not exist yet.
    private func ownCalendar() throws -> EKCalendar {
        if let existing = store.calendars(for: .event).first(where: { $0.title == name }) {
            return existing
        }
        // Pick the source by what it demonstrably supports rather than by its name: an
        // account may handle calendars but not reminders, and both are often called "iCloud".
        guard let source = store.sources.first(where: { !$0.calendars(for: .event).isEmpty }) else {
            throw Problem.noSource
        }
        let k = EKCalendar(for: .event, eventStore: store)
        k.title = name
        k.source = source
        try store.saveCalendar(k, commit: true)
        return k
    }

    private func ownList() throws -> EKCalendar {
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == name }) {
            return existing
        }
        guard let source = store.sources.first(where: { !$0.calendars(for: .reminder).isEmpty }) else {
            throw Problem.noSource
        }
        let k = EKCalendar(for: .reminder, eventStore: store)
        k.title = name
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
        e.calendar = try ownCalendar()
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
        r.calendar = try ownList()
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
        guard let k = try? ownCalendar() else { return false }
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
