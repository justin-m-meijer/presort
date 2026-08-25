import Foundation

/// Somewhere an approved proposal can end up.
///
/// The calendar and the reminder list were the only two for a long time, and `Core` simply
/// held an `if` for them. That `if` is the thing this protocol replaces: the second
/// destination is what pays for the split, the third and fourth get it for nothing.
///
/// Configuration stays on the destination itself -- how many days early a reminder fires is
/// no business of anything routing a proposal towards it.
protocol Destination: Sendable {
    /// Stored on the proposal, so undoing knows who to ask. Never translated: it ends up
    /// in a file that outlives a change of language.
    var id: String { get }

    func file(_ proposal: Proposal) async throws -> Filing
    func undo(_ proposal: Proposal) async throws
}

/// What came of an attempt to file something.
enum Filing {
    /// Created; the string identifies it well enough to undo it later.
    case filed(String)
    /// Already present. Not a failure and not a success: nothing was created, and saying
    /// "filed" would be a lie about somebody's calendar.
    case alreadyThere
}
