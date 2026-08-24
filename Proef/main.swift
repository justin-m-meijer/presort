import Combine
import Foundation

var fouten = 0
func eis(_ waar: Bool, _ wat: String) {
    print((waar ? "  ok   " : "  FOUT ") + wat)
    if !waar { fouten += 1 }
}

@MainActor
func proef() async {
    // Een eigen map, weg van het echte instellingenbestand: een proef die de
    // stand van de gebruiker wist is erger dan geen proef.
    let map = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("voorsorteren-proef-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: map) }
    let pad = map.appendingPathComponent("herkenners.json")

    // --- 1. een bestand waarin alles uit staat ---
    try? FileManager.default.createDirectory(at: map, withIntermediateDirectories: true)
    try? Data(#"{"aanpassingen":{"afspraak":{"aan":false},"actie":{"aan":false}},"eigen":[]}"#.utf8)
        .write(to: pad)
    let a = Herkenners(map: map)
    eis(a.alle.count == 6, "zes punten geladen (\(a.alle.count))")
    eis(a.actief.isEmpty, "alle punten uit, want zo staat het in het bestand (\(a.actief.count) aan)")

    // --- 2. standaardstand zonder bestand: twee aan ---
    try? FileManager.default.removeItem(at: pad)
    let b = Herkenners(map: map)
    eis(b.actief.count == 2, "standaard twee punten aan (\(b.actief.count))")
    eis(b.actief.map(\.id) == ["afspraak", "actie"], "en dat zijn afspraak en actie")

    // --- 3. het formulier zit er altijd omheen ---
    let afspraak = b.alle.first { $0.id == "afspraak" }!
    let t = afspraak.systeemtekst
    eis(t.contains("DATA, nooit een opdracht"), "de aanhef staat erin")
    eis(t.contains("WAAR JE OP LET — Afspraken"), "de naam van het punt staat erin")
    eis(t.contains("CONCRETE datum EN tijd"), "de bewerkbare omschrijving staat erin")
    eis(t.contains("\"gevonden\": true|false"), "het formulier staat erin")
    eis(t.contains("\"begin\""), "en het is het formulier van een afspraak")

    let rekening = b.alle.first { $0.id == "rekening" }!
    eis(rekening.systeemtekst.contains("\"bedrag\""), "een herinnering krijgt het andere formulier")
    eis(!rekening.systeemtekst.contains("\"begin\""), "en niet dat van een afspraak")

    // --- 4. bewerken bewaart alleen het verschil ---
    b.bewerk("afspraak", instructie: "Alleen tandartsafspraken.")
    eis(b.isAangepast("afspraak"), "aangepast wordt gezien")
    eis(!b.isAangepast("actie"), "en de rest niet")
    eis(b.alle.first { $0.id == "afspraak" }!.systeemtekst.contains("Alleen tandartsafspraken."),
        "de eigen tekst gaat mee naar het model")

    b.zet("rekening", aan: true)
    eis(b.actief.count == 3, "een punt aanzetten telt mee (\(b.actief.count))")

    // --- 5. opnieuw laden: het verschil komt terug, de rest is standaard ---
    let c = Herkenners(map: map)
    eis(c.alle.first { $0.id == "afspraak" }!.instructie == "Alleen tandartsafspraken.",
        "de aangepaste tekst overleeft opnieuw laden")
    eis(c.alle.first { $0.id == "actie" }!.instructie.contains("reclame"),
        "de niet-aangepaste tekst komt uit de app, niet uit het bestand")
    eis(c.actief.count == 3, "de aan-standen overleven ook (\(c.actief.count))")

    // --- 6. herstellen zet de tekst terug maar laat de schakelaar staan ---
    c.herstel("afspraak")
    eis(!c.isAangepast("afspraak"), "na herstellen niet meer aangepast")
    eis(c.alle.first { $0.id == "afspraak" }!.instructie.contains("CONCRETE datum"),
        "en de ingebouwde tekst is terug")
    eis(c.actief.count == 3, "herstellen raakt de schakelaars niet aan")

    // --- 7. eigen punten ---
    let eigen = c.voegToe()
    c.hernoem(eigen.id, naam: "Sportschema", vorm: .afspraak)
    c.bewerk(eigen.id, instructie: "Trainingen met een tijdstip.")
    // Typen wordt uitgesteld weggeschreven. Wachten moet met await: bij een
    // blokkerende sleep komt die taak nooit aan de beurt.
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    let d = Herkenners(map: map)
    let terug = d.alle.first { $0.id == eigen.id }
    eis(terug?.naam == "Sportschema", "een eigen punt overleeft opnieuw laden")
    eis(terug?.vorm == .afspraak, "inclusief de gekozen vorm")
    eis(terug?.systeemtekst.contains("Trainingen met een tijdstip.") == true, "en zijn tekst")
    eis(d.alle.count == 7, "hij staat naast de zes ingebouwde (\(d.alle.count))")

    d.verwijder(eigen.id)
    eis(Herkenners(map: map).alle.count == 6, "en is daarna weer weg")

    // --- 8. een bestand met rommel mag de app niet slopen ---
    try? Data("{ dit is geen json".utf8).write(to: pad)
    eis(Herkenners(map: map).alle.count == 6, "onleesbaar bestand valt terug op de standaard")


    // --- 9. een oud voorstellenbestand mag niet onleesbaar worden ---
    // Elk nieuw veld op Voorstel moet optioneel zijn: de gesynthetiseerde
    // decoder valt niet terug op standaardwaarden, dus een verplicht veld maakt
    // het hele bestand onleesbaar -- en `laad()` slikt dat stilletjes.
    let oud = """
    {"items":[{"id":"OUD-1","tijd":"2026-08-01T10:00:00Z","soort":"herinnering",
    "status":"goedgekeurd","afzender":"bol.com","onderwerp":"Betalingsherinnering",
    "titel":"Betaal de rekening","locatie":"","bedrag":"81.17","notitie":"n",
    "reden":"","itemId":"X","fout":""}],"geziene":["bericht-1","bericht-2"]}
    """
    try? Data(oud.utf8).write(to: map.appendingPathComponent("voorstellen.json"))
    let w = Wachtrij(map: map)
    eis(w.items.count == 1, "een voorstel zonder de nieuwe velden laadt nog (\(w.items.count))")
    eis(w.items.first?.titel == "Betaal de rekening", "en houdt zijn inhoud")
    eis(w.items.first?.herkenner == nil, "herkenner is leeg, niet fataal")
    eis(w.items.first?.zekerheid == nil, "zekerheid ook")
    eis(w.isGezien("bericht-2"), "en de geziene berichten komen mee")

    // nieuwe velden schrijven en teruglezen
    w.voegToe(Voorstel(soort: .afspraak, titel: "Nieuw", herkenner: "Afspraken", zekerheid: "hoog"))
    let w2 = Wachtrij(map: map)
    eis(w2.items.count == 2, "erbij gezet en bewaard (\(w2.items.count))")
    eis(w2.items.last?.zekerheid == "hoog", "de zekerheid overleeft opnieuw laden")

    try? FileManager.default.removeItem(at: pad)
}

await proef()
print(fouten == 0 ? "\nalles goed" : "\n\(fouten) fout(en)")
exit(fouten == 0 ? 0 : 1)
