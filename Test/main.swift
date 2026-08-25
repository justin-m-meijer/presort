import Combine
import Foundation

var failures = 0
func expect(_ ok: Bool, _ what: String) {
    print((ok ? "  ok   " : "  FAIL ") + what)
    if !ok { failures += 1 }
}

/// The languages that ship with the app. Listed here so a new .lproj nobody finished
/// translating fails the tests instead of shipping half empty.
let languages = ["en", "nl", "fr", "de"]

/// Every key the app looks up. A missing one makes the app show the key itself -- the kind
/// of thing you only notice once somebody with a French Mac opens it.
let requiredKeys: [String] = {
    var keys = ["prompt.preamble", "prompt.watch", "prompt.reply", "prompt.closing",
                "schema.event", "schema.reminder", "shape.event", "shape.reminder",
                "detector.new.name", "detector.new.instruction"]
    for id in Detector.builtInIds {
        keys += ["detector.\(id).name", "detector.\(id).summary", "detector.\(id).instruction"]
    }
    return keys
}()

@MainActor
func run() async {
    // A folder of its own, away from the real settings file: a test that wipes the user's
    // configuration is worse than no test at all.
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("presort-test-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("herkenners.json")

    // --- 0. the catalogue itself resolves ---
    // Without this every lookup falls back to its own key, and the tests below would still
    // pass while the app showed "prompt.preamble" on screen.
    expect(Detector.preamble != "prompt.preamble", "the string catalogue is found")

    // --- 1. a file with everything switched off ---
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? Data(#"{"aanpassingen":{"afspraak":{"aan":false},"actie":{"aan":false}},"eigen":[]}"#.utf8)
        .write(to: path)
    // Counted from the source of truth rather than written out: adding a built-in point
    // should not be a reason for a test to fail.
    let builtIn = Detector.builtInIds.count
    let a = Detectors(folder: folder)
    expect(a.all.count == builtIn, "all \(builtIn) built-in detectors loaded (\(a.all.count))")
    expect(a.active.isEmpty, "all off, because that is what the file says (\(a.active.count) on)")

    // --- 2. default state without a file: two on ---
    try? FileManager.default.removeItem(at: path)
    let b = Detectors(folder: folder)
    expect(b.active.count == 2, "two detectors on by default (\(b.active.count))")
    expect(b.active.map(\.id) == ["afspraak", "actie"], "and those are afspraak and actie")

    // --- 3. the frame always wraps the instruction ---
    // Asserted on structure, not on wording: the wording comes from the string catalogue
    // and differs per language.
    let appointment = b.all.first { $0.id == "afspraak" }!
    let prompt = appointment.systemText
    expect(prompt.contains(appointment.name), "the detector name is in the prompt")
    expect(prompt.contains(appointment.instruction), "the editable instruction is in the prompt")
    expect(prompt.contains(Detector.preamble), "the preamble is in the prompt")
    expect(prompt.contains(Detector.closing), "the closing line is in the prompt")

    // The JSON keys are the same in every language: Scanner reads them by name.
    let invoice = b.all.first { $0.id == "rekening" }!
    expect(prompt.contains("\"gevonden\""), "the schema is in the prompt")
    expect(prompt.contains("\"begin\""), "and it is the schema of an appointment")
    expect(invoice.systemText.contains("\"bedrag\""), "a reminder gets the other schema")
    expect(!invoice.systemText.contains("\"begin\""), "and not the appointment one")

    // Every shape must be reachable, and each built-in point must claim one that exists.
    expect(Set(b.all.map(\.kind)).count >= 3, "the built-in points cover more than one shape")
    expect(b.all.contains { $0.kind == .document }, "there is a document point")
    expect(b.all.first { $0.kind == .document }?.enabled == false,
           "and it is off by default, like every point that needs setting up")

    // --- 4. editing stores only the difference ---
    b.edit("afspraak", instruction: "Only dentist appointments.")
    expect(b.isEdited("afspraak"), "an edit is recognised")
    expect(!b.isEdited("actie"), "and the rest is not")
    expect(b.all.first { $0.id == "afspraak" }!.systemText.contains("Only dentist appointments."),
           "the edited text reaches the model")

    b.set("rekening", enabled: true)
    expect(b.active.count == 3, "switching one on counts (\(b.active.count))")

    // --- 5. reloading: the difference comes back, the rest is default ---
    let c = Detectors(folder: folder)
    expect(c.all.first { $0.id == "afspraak" }!.instruction == "Only dentist appointments.",
           "the edited text survives a reload")
    expect(c.all.first { $0.id == "actie" }!.instruction == Detector.builtIn
               .first { $0.id == "actie" }!.instruction,
           "the untouched text comes from the catalogue, not from the file")
    expect(c.active.count == 3, "the on/off states survive too (\(c.active.count))")

    // --- 6. restoring puts the text back but leaves the switch alone ---
    c.restore("afspraak")
    expect(!c.isEdited("afspraak"), "no longer customised after restoring")
    expect(c.all.first { $0.id == "afspraak" }!.instruction == appointment.instruction,
           "and the built-in text is back")
    expect(c.active.count == 3, "restoring does not touch the switches")

    // --- 7. detectors of your own ---
    let own = c.add()
    c.rename(own.id, name: "Training schedule", kind: .event)
    c.edit(own.id, instruction: "Sessions with a time.")
    // Typing is written out on a delay. Waiting has to use await: with a blocking sleep
    // that task never gets its turn.
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    let d = Detectors(folder: folder)
    let back = d.all.first { $0.id == own.id }
    expect(back?.name == "Training schedule", "a detector of your own survives a reload")
    expect(back?.kind == .event, "including the chosen shape")
    expect(back?.systemText.contains("Sessions with a time.") == true, "and its text")
    expect(d.all.count == builtIn + 1,
           "it sits alongside the built-in ones (\(d.all.count))")

    d.remove(own.id)
    expect(Detectors(folder: folder).all.count == builtIn, "and is gone again afterwards")

    // --- 8. a corrupt file must not take the app down ---
    try? Data("{ this is not json".utf8).write(to: path)
    expect(Detectors(folder: folder).all.count == builtIn,
           "an unreadable file falls back to defaults")

    // --- 9. an older proposals file must stay readable ---
    // Every new field on Voorstel has to be optional: the synthesised decoder does not fall
    // back to default values, so one required field makes the whole file unreadable -- and
    // `laad()` swallows that silently.
    let old = """
    {"items":[{"id":"OLD-1","tijd":"2026-08-01T10:00:00Z","soort":"herinnering",
    "status":"goedgekeurd","afzender":"bol.com","onderwerp":"Payment reminder",
    "titel":"Pay the bill","locatie":"","bedrag":"81.17","notitie":"n",
    "reden":"","itemId":"X","fout":""}],"geziene":["message-1","message-2"]}
    """
    try? Data(old.utf8).write(to: folder.appendingPathComponent("voorstellen.json"))
    let queue = Queue(folder: folder)
    expect(queue.items.count == 1, "a proposal without the newer fields still loads (\(queue.items.count))")
    expect(queue.items.first?.title == "Pay the bill", "and keeps its contents")
    expect(queue.items.first?.detector == nil, "herkenner is empty, not fatal")
    expect(queue.items.first?.confidence == nil, "zekerheid too")
    expect(queue.items.first?.destination == nil, "and bestemming, added later still")
    expect(queue.isSeen("message-2"), "and the seen messages come along")

    // write the new fields and read them back
    queue.add(Proposal(category: .event, title: "New", detector: "Appointments", confidence: "hoog"))
    let queue2 = Queue(folder: folder)
    expect(queue2.items.count == 2, "added and saved (\(queue2.items.count))")
    expect(queue2.items.last?.confidence == "hoog", "the confidence survives a reload")

    try? FileManager.default.removeItem(at: path)

    // Sentences from older files must still read as sentences, not as raw leftovers.
    for (stored, expected) in [("niets van de 6 punten", "skip.nothingRelevant"),
                               ("none of the 6 points", "skip.nothingRelevant"),
                               ("geen afspraken", "skip.nothingRelevant"),
                               ("no readable content", "skip.noContent"),
                               ("already there", "status.alreadyThere"),
                               ("undone", "status.undone")] {
        expect(Proposal.Note.text(stored) == t(expected),
               "an older \"\(stored)\" still reads properly")
    }
    expect(Proposal.Note.text("Paperless answered with code 500") ==
           "Paperless answered with code 500", "and a server's own words are left alone")

    // --- 10. the four languages carry exactly the same keys ---
    // This is the check that catches a forgotten translation. Asserting only on the keys
    // the test happens to name would let a new one slip into English alone, and a missing
    // key shows the user the key itself.
    func keys(_ language: String) -> Set<String> {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Presort/Resources/\(language).lproj/Localizable.strings")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("\""), let close = line.dropFirst().firstIndex(of: "\"")
            else { return nil }
            return String(line[line.index(after: line.startIndex)..<close])
        })
    }

    let english = keys("en")
    expect(english.count > 150, "the English catalogue is complete (\(english.count) keys)")
    for language in languages.dropFirst() {
        let mine = keys(language)
        let missing = english.subtracting(mine).sorted()
        let extra = mine.subtracting(english).sorted()
        expect(missing.isEmpty && extra.isEmpty,
               "\(language): same \(english.count) keys as English"
               + (missing.isEmpty ? "" : " -- missing \(missing)")
               + (extra.isEmpty ? "" : " -- unknown \(extra)"))
    }

    // --- 11. every language carries every key the prompt needs ---
    // Read from the source files rather than the built bundle, so a missing translation is
    // caught before anything is packaged.
    let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Presort/Resources")
    for language in languages {
        let file = resources.appendingPathComponent("\(language).lproj/Localizable.strings")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            expect(false, "\(language): Localizable.strings not found")
            continue
        }
        let missing = requiredKeys.filter { !text.contains("\"\($0)\"") }
        expect(missing.isEmpty,
               "\(language): all \(requiredKeys.count) keys present"
               + (missing.isEmpty ? "" : " -- missing \(missing)"))
        // The JSON keys must be identical everywhere: Scanner reads them by name.
        let schemaKeys = ["gevonden", "titel", "begin", "eind", "locatie",
                          "wat", "uiterlijk", "bedrag", "zekerheid",
                          "datum", "afzender", "trefwoorden"]
        let stray = schemaKeys.filter { !text.contains("\\\"\($0)\\\"") }
        expect(stray.isEmpty, "\(language): schema keeps its keys"
               + (stray.isEmpty ? "" : " -- missing \(stray)"))
    }
}

await run()
print(failures == 0 ? "\nall good" : "\n\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
