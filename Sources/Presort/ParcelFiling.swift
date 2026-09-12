import Foundation

/// Where a parcel goes: into Parcel, and into your reminders on the day it arrives, with the
/// tracking number in the note.
///
/// Either half can be missing. Parcel may not be connected, and plenty of shipping mails
/// never say which day. What gets filed is whatever of the two can be done now; a reminder
/// without a day follows later, once Parcel has heard from the carrier
/// (`Core.followParcels`). The item id keeps both parts, space separated, so each can be
/// found again: `parcel:<carrier>:<number> reminder:<id>`.
struct ParcelFiling: Destination {
    let parcel: ParcelApp?
    let calendar: CalendarStore?

    var id: String { "parcel" }

    func file(_ proposal: Proposal) async throws -> Filing {
        var parts: [String] = []
        var carrierName = proposal.carrier ?? ""
        if let parcel {
            let carriers = await ParcelCarriers.shared.all()
            let region = ParcelApp.macRegion
            if let c = ParcelApp.carrier(for: proposal, among: carriers, region: region) {
                carrierName = c.name
            }
            switch try await parcel.add(proposal, carriers: carriers, region: region) {
            case .filed(let id):
                parts.append(id)
            case .alreadyThere:
                // Already tracked, perhaps added by hand. Still worth its reminder.
                parts.append("parcel:known:\(proposal.trackingNumber ?? "")")
            }
        }
        if let calendar, let day = proposal.dueDate, ParcelFiling.stillAhead(day) {
            let id = try await calendar.makeParcelReminder(
                title: ParcelFiling.title(proposal), arriving: day,
                note: ParcelFiling.note(proposal, carrier: carrierName))
            parts.append("reminder:" + id)
        }
        guard !parts.isEmpty else { throw ParcelApp.Problem.nothingToDo }
        return .filed(parts.joined(separator: " "))
    }

    /// Parcel cannot take a delivery back, so the window offers no undo for parcels. Should
    /// anything ask all the same, the reminder is the part that can go.
    func undo(_ proposal: Proposal) async throws {
        guard let calendar, let id = ParcelFiling.reminderId(in: proposal.itemId) else { return }
        try await calendar.remove(reminderId: id)
    }

    static func reminderId(in itemId: String) -> String? {
        itemId.split(separator: " ").first { $0.hasPrefix("reminder:") }.map { String($0.dropFirst(9)) }
    }

    static func inParcel(_ itemId: String) -> Bool {
        itemId.split(separator: " ").contains { $0.hasPrefix("parcel:") }
    }

    /// Today counts: a parcel due this afternoon is still worth the reminder.
    static func stillAhead(_ day: Date) -> Bool {
        day > Date() || Calendar.current.isDateInToday(day)
    }

    static func title(_ p: Proposal) -> String {
        String(format: t("parcel.reminder.title"), p.title)
    }

    static func note(_ p: Proposal, carrier: String) -> String {
        String(format: t("parcel.reminder.note"), p.trackingNumber ?? "",
               carrier.isEmpty ? "—" : carrier, p.sender, p.subject)
    }
}
