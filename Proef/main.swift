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
    for id in Herkenner.builtInIds {
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
    expect(Herkenner.aanhef != "prompt.preamble", "the string catalogue is found")

    // --- 1. a file with everything switched off ---
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? Data(#"{"aanpassingen":{"afspraak":{"aan":false},"actie":{"aan":false}},"eigen":[]}"#.utf8)
        .write(to: path)
    let a = Herkenners(map: folder)
    expect(a.alle.count == 6, "six detectors loaded (\(a.alle.count))")
    expect(a.actief.isEmpty, "all off, because that is what the file says (\(a.actief.count) on)")

    // --- 2. default state without a file: two on ---
    try? FileManager.default.removeItem(at: path)
    let b = Herkenners(map: folder)
    expect(b.actief.count == 2, "two detectors on by default (\(b.actief.count))")
    expect(b.actief.map(\.id) == ["afspraak", "actie"], "and those are afspraak and actie")

    // --- 3. the frame always wraps the instruction ---
    // Asserted on structure, not on wording: the wording comes from the string catalogue
    // and differs per language.
    let appointment = b.alle.first { $0.id == "afspraak" }!
    let prompt = appointment.systeemtekst
    expect(prompt.contains(appointment.naam), "the detector name is in the prompt")
    expect(prompt.contains(appointment.instructie), "the editable instruction is in the prompt")
    expect(prompt.contains(Herkenner.aanhef), "the preamble is in the prompt")
    expect(prompt.contains(Herkenner.slot), "the closing line is in the prompt")

    // The JSON keys are the same in every language: Scanner reads them by name.
    let invoice = b.alle.first { $0.id == "rekening" }!
    expect(prompt.contains("\"gevonden\""), "the schema is in the prompt")
    expect(prompt.contains("\"begin\""), "and it is the schema of an appointment")
    expect(invoice.systeemtekst.contains("\"bedrag\""), "a reminder gets the other schema")
    expect(!invoice.systeemtekst.contains("\"begin\""), "and not the appointment one")

    // --- 4. editing stores only the difference ---
    b.bewerk("afspraak", instructie: "Only dentist appointments.")
    expect(b.isAangepast("afspraak"), "an edit is recognised")
    expect(!b.isAangepast("actie"), "and the rest is not")
    expect(b.alle.first { $0.id == "afspraak" }!.systeemtekst.contains("Only dentist appointments."),
           "the edited text reaches the model")

    b.zet("rekening", aan: true)
    expect(b.actief.count == 3, "switching one on counts (\(b.actief.count))")

    // --- 5. reloading: the difference comes back, the rest is default ---
    let c = Herkenners(map: folder)
    expect(c.alle.first { $0.id == "afspraak" }!.instructie == "Only dentist appointments.",
           "the edited text survives a reload")
    expect(c.alle.first { $0.id == "actie" }!.instructie == Herkenner.ingebouwd
               .first { $0.id == "actie" }!.instructie,
           "the untouched text comes from the catalogue, not from the file")
    expect(c.actief.count == 3, "the on/off states survive too (\(c.actief.count))")

    // --- 6. restoring puts the text back but leaves the switch alone ---
    c.herstel("afspraak")
    expect(!c.isAangepast("afspraak"), "no longer customised after restoring")
    expect(c.alle.first { $0.id == "afspraak" }!.instructie == appointment.instructie,
           "and the built-in text is back")
    expect(c.actief.count == 3, "restoring does not touch the switches")

    // --- 7. detectors of your own ---
    let own = c.voegToe()
    c.hernoem(own.id, naam: "Training schedule", vorm: .afspraak)
    c.bewerk(own.id, instructie: "Sessions with a time.")
    // Typing is written out on a delay. Waiting has to use await: with a blocking sleep
    // that task never gets its turn.
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    let d = Herkenners(map: folder)
    let back = d.alle.first { $0.id == own.id }
    expect(back?.naam == "Training schedule", "a detector of your own survives a reload")
    expect(back?.vorm == .afspraak, "including the chosen shape")
    expect(back?.systeemtekst.contains("Sessions with a time.") == true, "and its text")
    expect(d.alle.count == 7, "it sits alongside the six built-in ones (\(d.alle.count))")

    d.verwijder(own.id)
    expect(Herkenners(map: folder).alle.count == 6, "and is gone again afterwards")

    // --- 8. a corrupt file must not take the app down ---
    try? Data("{ this is not json".utf8).write(to: path)
    expect(Herkenners(map: folder).alle.count == 6, "an unreadable file falls back to defaults")

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
    let queue = Wachtrij(map: folder)
    expect(queue.items.count == 1, "a proposal without the newer fields still loads (\(queue.items.count))")
    expect(queue.items.first?.titel == "Pay the bill", "and keeps its contents")
    expect(queue.items.first?.herkenner == nil, "herkenner is empty, not fatal")
    expect(queue.items.first?.zekerheid == nil, "zekerheid too")
    expect(queue.isGezien("message-2"), "and the seen messages come along")

    // write the new fields and read them back
    queue.voegToe(Voorstel(soort: .afspraak, titel: "New", herkenner: "Appointments", zekerheid: "hoog"))
    let queue2 = Wachtrij(map: folder)
    expect(queue2.items.count == 2, "added and saved (\(queue2.items.count))")
    expect(queue2.items.last?.zekerheid == "hoog", "the confidence survives a reload")

    try? FileManager.default.removeItem(at: path)

    // --- 10. every language carries every key ---
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
                          "wat", "uiterlijk", "bedrag", "zekerheid"]
        let stray = schemaKeys.filter { !text.contains("\\\"\($0)\\\"") }
        expect(stray.isEmpty, "\(language): schema keeps its keys"
               + (stray.isEmpty ? "" : " -- missing \(stray)"))
    }
}

await run()
print(failures == 0 ? "\nall good" : "\n\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
