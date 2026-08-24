import Foundation

/// The loop: fetch mail, put it to the model, check the answer, and turn it into a
/// proposal. Nothing is created here -- that happens only when the user presses approve
/// in the window.
@MainActor
final class Scanner: ObservableObject {
    @Published var bezig = false
    @Published var laatsteMelding = ""

    private let instellingen: Instellingen
    private let wachtrij: Wachtrij
    private let herkenners: Herkenners

    init(instellingen: Instellingen, wachtrij: Wachtrij, herkenners: Herkenners) {
        self.instellingen = instellingen
        self.wachtrij = wachtrij
        self.herkenners = herkenners
    }

    /// What a run produced. The caller decides what happens with it: the window puts it
    /// in the status bar, a background run turns it into a notification.
    struct Uitkomst {
        var nagekeken = 0
        var voorgesteld = 0
        /// Messages where Mail or the model dropped out. Those stay open for the next
        /// run, so they do not count as checked.
        var mislukt = 0
        var titels: [String] = []
        /// The proposals from this run, so the caller can handle them without guessing
        /// which ones are new.
        var ids: [String] = []
        var melding = ""
    }

    /// `voortgang` is called during the run with the line that belongs in the status
    /// bar. Without that hand-off you only see the outcome afterwards.
    func kijkNa(voortgang: (String) -> Void = { _ in }) async -> Uitkomst {
        var uit = Uitkomst()
        guard !bezig else { return uit }
        guard instellingen.isIngericht else {
            uit.melding = t("scan.notConfigured")
            laatsteMelding = uit.melding
            return uit
        }
        let punten = herkenners.actief
        guard !punten.isEmpty else {
            uit.melding = t("scan.nothingEnabled")
            laatsteMelding = uit.melding
            return uit
        }

        bezig = true
        defer { bezig = false }

        let postvak = Postvak(account: instellingen.account, postvak: instellingen.postvak)
        let client = ModelClient(eindpunt: instellingen.eindpunt,
                                 sleutel: instellingen.sleutel,
                                 model: instellingen.model)

        voortgang(String(format: t("scan.fetching"), instellingen.postvak))

        let berichten: [Postvak.Bericht]
        do {
            berichten = try postvak.recent(dagen: instellingen.dagen, limiet: 40)
        } catch {
            uit.melding = error.localizedDescription
            laatsteMelding = uit.melding
            return uit
        }

        let nieuw = berichten.filter { !wachtrij.isGezien($0.id) }
        guard !nieuw.isEmpty else {
            uit.melding = String(format: t("scan.nothingNew"), instellingen.postvak)
            laatsteMelding = uit.melding
            return uit
        }

        var voorgesteld = 0
        for b in nieuw.prefix(15) {
            voortgang(String(format: t("scan.working"), String(b.onderwerp.prefix(40))))

            // A message only counts as seen once it has been judged: either a proposal
            // came out, or it was deliberately skipped. If Mail or the model drops out it
            // stays open -- otherwise the message vanishes quietly and nobody ever looks
            // at it again.
            let tekst: String
            do {
                tekst = try postvak.inhoud(van: b.id)
            } catch {
                uit.mislukt += 1
                continue
            }

            guard !tekst.isEmpty else {
                // Read fine, there was simply nothing in it. That is a judgement.
                noteerOvergeslagen(b, t("skip.noContent"))
                wachtrij.markeerGezien(b.id)
                uit.nagekeken += 1
                continue
            }

            // The frame around the message. It is part of the prompt, so it follows the
            // app language: an English frame around Dutch keys is what made the model
            // answer in the wrong language before.
            let kader = """
            \(String(format: t("frame.today"), Datums.vandaag()))
            \(t("frame.sender")) \(b.afzender)
            \(t("frame.subject")) \(b.onderwerp)

            \(t("frame.untrusted"))
            \(tekst)
            \(t("frame.end"))
            """

            // Every enabled point is one question, in order, until something hits. A
            // message yields at most one proposal: two reminders out of the same mail are
            // nearly always the same thing said twice. A failure from the model is not a
            // judgement, so nothing is marked after one.
            var voorstel: Voorstel?
            // Unreadable JSON is as much a non-judgement as a network failure: only once
            // at least one answer could be read do we know anything.
            var begrepen = false
            do {
                for punt in punten {
                    let antwoord = try await client.vraag(systeem: punt.systeemtekst,
                                                          gebruiker: kader)
                    guard let o = ModelClient.jsonUit(antwoord) else { continue }
                    begrepen = true
                    voorstel = punt.vorm == .afspraak
                        ? maakAfspraakVoorstel(o, b, punt)
                        : maakActieVoorstel(o, b, punt)
                    if voorstel != nil { break }
                }
            } catch {
                uit.mislukt += 1
                continue
            }

            guard begrepen else {
                uit.mislukt += 1
                continue
            }

            if let v = voorstel {
                wachtrij.voegToe(v)
                voorgesteld += 1
                uit.titels.append(v.titel)
                uit.ids.append(v.id)
            } else {
                noteerOvergeslagen(b, punten.count == 1
                    ? String(format: t("skip.noneOfOne"), punten[0].naam.lowercased())
                    : String(format: t("skip.noneOfMany"), punten.count))
            }
            wachtrij.markeerGezien(b.id)
            uit.nagekeken += 1
        }

        uit.voorgesteld = voorgesteld
        let staart = uit.mislukt == 0
            ? ""
            : String(format: t("scan.failedTail"), uit.mislukt)
        uit.melding = (voorgesteld == 0
            ? String(format: t("scan.nothingFound"), uit.nagekeken)
            : String(format: t("scan.found"), voorgesteld, uit.nagekeken)) + staart
        laatsteMelding = uit.melding
        return uit
    }

    // MARK: checking the answer

    private func zekerheid(_ o: [String: Any]) -> String? {
        (o["zekerheid"] as? String)?.lowercased()
    }

    private func zekerGenoeg(_ o: [String: Any]) -> Bool {
        guard instellingen.alleenHogeZekerheid else { return true }
        return (o["zekerheid"] as? String)?.lowercased() == "hoog"
    }

    private func maakAfspraakVoorstel(_ o: [String: Any], _ b: Postvak.Bericht,
                                      _ punt: Herkenner) -> Voorstel? {
        guard (o["gevonden"] as? Bool) == true, zekerGenoeg(o) else { return nil }
        let titel = (o["titel"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard titel.count >= 2, titel.count <= 120,
              let begin = Datums.lees(o["begin"] as? String),
              Datums.redelijk(begin) else { return nil }
        let eind = Datums.lees(o["eind"] as? String) ?? begin.addingTimeInterval(3600)
        guard eind > begin, eind.timeIntervalSince(begin) < 60 * 60 * 48 else { return nil }

        return Voorstel(soort: .afspraak, afzender: b.afzender, onderwerp: b.onderwerp,
                        titel: titel, begin: begin, eind: eind,
                        locatie: String((o["locatie"] as? String ?? "").prefix(200)),
                        notitie: notitie(b), herkenner: punt.naam, zekerheid: zekerheid(o))
    }

    private func maakActieVoorstel(_ o: [String: Any], _ b: Postvak.Bericht,
                                   _ punt: Herkenner) -> Voorstel? {
        guard (o["gevonden"] as? Bool) == true, zekerGenoeg(o) else { return nil }
        let wat = (o["wat"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard wat.count >= 4, wat.count <= 200 else { return nil }
        let uiterlijk = Datums.lees(o["uiterlijk"] as? String)
        if let u = uiterlijk, !Datums.redelijk(u) { return nil }

        let bedrag = String((o["bedrag"] as? String ?? "").prefix(40))
        return Voorstel(soort: .herinnering, afzender: b.afzender, onderwerp: b.onderwerp,
                        titel: wat, uiterlijk: uiterlijk, bedrag: bedrag,
                        notitie: notitie(b) + (bedrag.isEmpty ? "" : String(format: t("note.amount"), bedrag)),
                        herkenner: punt.naam, zekerheid: zekerheid(o))
    }

    private func notitie(_ b: Postvak.Bericht) -> String {
        String(format: t("note.detected"), b.afzender, b.onderwerp)
    }

    private func noteerOvergeslagen(_ b: Postvak.Bericht, _ reden: String) {
        wachtrij.voegToe(Voorstel(soort: .overgeslagen, afzender: b.afzender,
                                  onderwerp: b.onderwerp, reden: reden))
    }
}

/// The locale the dates on screen follow. Deliberately not `Locale.current`: a Mac set to
/// Dutch running the app in English would otherwise put Dutch month names next to English
/// labels. It follows the language the app is actually showing.
let appLocale = Locale(identifier: catalogus.preferredLocalizations.first ?? "en")

enum Datums {
    static func vandaag() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func lees(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        for patroon in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.dateFormat = patroon
            f.locale = Locale(identifier: "en_US_POSIX")
            if var d = f.date(from: s) {
                if patroon == "yyyy-MM-dd" {
                    d = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d
                }
                return d
            }
        }
        return nil
    }

    /// Between roughly a month back and a year ahead. Anything outside that is invented.
    static func redelijk(_ d: Date) -> Bool {
        d > Date().addingTimeInterval(-86400 * 31) && d < Date().addingTimeInterval(86400 * 400)
    }

    static func kort(_ d: Date?) -> String {
        guard let d else { return t("date.none") }
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = "EEE d MMM, HH:mm"
        return f.string(from: d)
    }

    /// When the alert fires for a deadline, or nil if there is none. Both the card and
    /// `Agenda.maakHerinnering` use this: if those two did their own arithmetic, the
    /// window would promise something other than what happens.
    static func seintje(uiterlijk: Date?, voorsprongDagen: Int) -> Date? {
        guard let d = uiterlijk, voorsprongDagen > 0 else { return nil }
        let wek = d.addingTimeInterval(-Double(voorsprongDagen) * 86400)
        return wek > Date() ? wek : nil
    }

    /// "Fri 4 Sep 2026, 09:00"
    static func lang(_ d: Date) -> String {
        vorm("EEE d MMM yyyy, HH:mm").string(from: d)
    }

    /// "Fri 4 Sep 2026"
    static func langDag(_ d: Date) -> String {
        vorm("EEE d MMM yyyy").string(from: d)
    }

    /// Two moments; the day appears only once when it is the same day.
    static func reeks(_ begin: Date?, _ eind: Date?) -> String {
        guard let begin else { return t("date.none") }
        guard let eind else { return lang(begin) }
        if Calendar.current.isDate(begin, inSameDayAs: eind) {
            return lang(begin) + " – " + vorm("HH:mm").string(from: eind)
        }
        return lang(begin) + " – " + lang(eind)
    }

    private static func vorm(_ patroon: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = patroon
        return f
    }

    static func klok(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func kortDag(_ d: Date?) -> String {
        guard let d else { return t("date.none") }
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = "EEE d MMMM"
        return f.string(from: d)
    }
}
