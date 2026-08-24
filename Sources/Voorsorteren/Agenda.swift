import EventKit
import Foundation

/// Writes only into a calendar and a reminder list of its own. The user's existing
/// calendars are read but never touched: what the app proposes stays separate, and
/// dragging it into a real calendar is how the user accepts it.
actor Agenda {
    private let store = EKEventStore()
    private let naam: String

    init(naam: String) { self.naam = naam }

    enum Fout: LocalizedError {
        case geenToegang(String)
        case geenBron
        case opslaanMislukt(String)

        var errorDescription: String? {
            switch self {
            case .geenToegang(let wat):
                return "No access to \(wat). Enable it in System Settings › Privacy & Security."
            case .geenBron: return "No account found to create the list in."
            case .opslaanMislukt(let m): return "Saving failed. \(m)"
            }
        }
    }

    func vraagToegang() async throws {
        if try await store.requestFullAccessToEvents() == false {
            throw Fout.geenToegang("Agenda")
        }
        if try await store.requestFullAccessToReminders() == false {
            throw Fout.geenToegang("Reminders")
        }
    }

    /// Our own calendar, created if it does not exist yet.
    private func eigenAgenda() throws -> EKCalendar {
        if let bestaand = store.calendars(for: .event).first(where: { $0.title == naam }) {
            return bestaand
        }
        // Pick the source by what it demonstrably supports rather than by its name: an
        // account may handle calendars but not reminders, and both are often called "iCloud".
        guard let bron = store.sources.first(where: { !$0.calendars(for: .event).isEmpty }) else {
            throw Fout.geenBron
        }
        let k = EKCalendar(for: .event, eventStore: store)
        k.title = naam
        k.source = bron
        try store.saveCalendar(k, commit: true)
        return k
    }

    private func eigenLijst() throws -> EKCalendar {
        if let bestaand = store.calendars(for: .reminder).first(where: { $0.title == naam }) {
            return bestaand
        }
        guard let bron = store.sources.first(where: { !$0.calendars(for: .reminder).isEmpty }) else {
            throw Fout.geenBron
        }
        let k = EKCalendar(for: .reminder, eventStore: store)
        k.title = naam
        k.source = bron
        try store.saveCalendar(k, commit: true)
        return k
    }

    func maakAfspraak(titel: String, begin: Date, eind: Date,
                      locatie: String, notitie: String) throws -> String {
        store.reset()
        let e = EKEvent(eventStore: store)
        e.title = titel
        e.startDate = begin
        e.endDate = eind
        if !locatie.isEmpty { e.location = locatie }
        e.notes = notitie
        e.calendar = try eigenAgenda()
        do { try store.save(e, span: .thisEvent, commit: true) }
        catch { throw Fout.opslaanMislukt(error.localizedDescription) }
        return e.eventIdentifier ?? ""
    }

    func maakHerinnering(wat: String, uiterlijk: Date?, notitie: String,
                         voorsprongDagen: Int = 0) throws -> String {
        store.reset()
        let r = EKReminder(eventStore: store)
        r.title = wat
        r.notes = notitie
        r.calendar = try eigenLijst()
        if let d = uiterlijk {
            // The deadline stays the deadline -- that is what shows in the list and what
            // you want to see. The alert comes earlier: on the final day, getting a parcel
            // back is usually no longer possible.
            r.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: d)
            // If that moment has already passed, `seintje` returns nil and the deadline
            // itself is all that is left. The window shows the same calculation, so what it
            // says is what happens here.
            if let wek = Datums.seintje(uiterlijk: d, voorsprongDagen: voorsprongDagen) {
                r.addAlarm(EKAlarm(absoluteDate: wek))
            }
        }
        do { try store.save(r, commit: true) }
        catch { throw Fout.opslaanMislukt(error.localizedDescription) }
        return r.calendarItemIdentifier
    }

    /// Does something with this title already exist around this time? Guards against
    /// duplicate work if the saved state is ever lost.
    func heeftAfspraak(titel: String, begin: Date) -> Bool {
        store.reset()
        guard let k = try? eigenAgenda() else { return false }
        let van = begin.addingTimeInterval(-3600)
        let tot = begin.addingTimeInterval(3600)
        let p = store.predicateForEvents(withStart: van, end: tot, calendars: [k])
        return store.events(matching: p).contains { $0.title == titel }
    }

    func verwijder(afspraakId: String) throws {
        store.reset()
        guard let e = store.event(withIdentifier: afspraakId) else { return }
        try store.remove(e, span: .thisEvent, commit: true)
    }

    func verwijder(herinneringId: String) throws {
        store.reset()
        guard let r = store.calendarItem(withIdentifier: herinneringId) as? EKReminder else { return }
        try store.remove(r, commit: true)
    }
}
