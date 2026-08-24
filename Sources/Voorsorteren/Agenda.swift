import EventKit
import Foundation

/// Schrijft uitsluitend in een eigen agenda en een eigen herinneringenlijst.
/// De bestaande agenda's van de gebruiker worden gelezen maar nooit aangeraakt:
/// wat de app voorstelt staat apart, en verslepen naar een echte agenda is de
/// manier waarop de gebruiker het overneemt.
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
                return "Geen toegang tot \(wat). Zet dat aan in Systeeminstellingen › Privacy en beveiliging."
            case .geenBron: return "Geen account gevonden om de lijst in te maken."
            case .opslaanMislukt(let m): return "Opslaan mislukte. \(m)"
            }
        }
    }

    func vraagToegang() async throws {
        if try await store.requestFullAccessToEvents() == false {
            throw Fout.geenToegang("Agenda")
        }
        if try await store.requestFullAccessToReminders() == false {
            throw Fout.geenToegang("Herinneringen")
        }
    }

    /// Eigen agenda, aangemaakt als hij nog niet bestaat.
    private func eigenAgenda() throws -> EKCalendar {
        if let bestaand = store.calendars(for: .event).first(where: { $0.title == naam }) {
            return bestaand
        }
        // De bron kiezen op wat hij aantoonbaar kan, niet op zijn naam: een account
        // kan agenda's aankunnen en herinneringen niet, en beide heten vaak "iCloud".
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
            // De uiterste datum blijft de uiterste datum -- die staat in de lijst
            // en die wil je zien. Het seintje komt eerder: op de laatste dag is
            // een pakket terugsturen meestal niet meer te doen.
            r.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: d)
            // Ligt dat moment al achter ons, dan geeft `seintje` nil terug en is
            // de uiterste datum zelf het enige dat nog helpt. Het venster toont
            // dezelfde som, dus wat daar staat is wat hier gebeurt.
            if let wek = Datums.seintje(uiterlijk: d, voorsprongDagen: voorsprongDagen) {
                r.addAlarm(EKAlarm(absoluteDate: wek))
            }
        }
        do { try store.save(r, commit: true) }
        catch { throw Fout.opslaanMislukt(error.localizedDescription) }
        return r.calendarItemIdentifier
    }

    /// Bestaat er al iets met deze titel rond dit tijdstip? Beschermt tegen dubbel
    /// werk als de opgeslagen stand ooit kwijtraakt.
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
