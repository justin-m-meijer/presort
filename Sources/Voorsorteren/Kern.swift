import Combine
import Foundation

/// Alles wat de app doet, los van waar het vandaan gevraagd wordt. Het venster
/// en het menubalk-item praten allebei hiertegen; daarom staat het niet meer in
/// de view. Een beurt op de achtergrond heeft namelijk geen venster nodig.
@MainActor
final class Kern: ObservableObject {
    let instellingen = Instellingen()
    let wachtrij = Wachtrij()
    let herkenners = Herkenners()
    let wekker = Wekker()

    @Published var melding = ""
    @Published var bezig = false

    private lazy var scanner = Scanner(instellingen: instellingen, wachtrij: wachtrij,
                                       herkenners: herkenners)
    private var agenda: Agenda?
    private var abonnementen = Set<AnyCancellable>()

    init() {
        // De wekker volgt de instelling: verzet je hem, dan gaat hij meteen mee.
        instellingen.$ritmeMinuten
            .removeDuplicates()
            .sink { [weak self] minuten in
                Task { @MainActor in self?.zetWekker(minuten) }
            }
            .store(in: &abonnementen)
    }

    /// Eenmalig bij het opstarten: toegang vragen en de wekker opwinden.
    func begin() async {
        MeldingBezorger.gedeeld.koppel()

        if agenda == nil {
            let a = Agenda(naam: instellingen.agendaNaam)
            agenda = a
            do { try await a.vraagToegang() }
            catch { melding = error.localizedDescription }
        }
        if instellingen.meldingen {
            await Meldingen.vraagToestemming()
        }
        zetWekker(instellingen.ritmeMinuten)
    }

    private func zetWekker(_ minuten: Int) {
        wekker.zet(elke: minuten) { [weak self] in
            await self?.kijkNa(vanzelf: true)
        }
    }

    // MARK: nakijken

    func kijkNa(vanzelf: Bool = false) async {
        guard !bezig else { return }

        // Een beurt uit zichzelf mag Mail niet wakker maken: dan opent er een
        // programma dat je bewust had afgesloten.
        if vanzelf && !Mail.draait {
            melding = "Overgeslagen: Mail draait niet."
            return
        }

        bezig = true
        let uit = await scanner.kijkNa { [weak self] regel in
            self?.melding = regel
        }
        bezig = false

        let zelf = instellingen.zetZelfIn ? await zetZelfIn(uit.ids) : ZelfGedaan()
        melding = uit.melding + zelf.staart
        wekker.schuifOp()

        if vanzelf, instellingen.meldingen, uit.voorgesteld > 0 {
            Meldingen.meld(kop: kopVoorMelding(uit, zelf),
                           tekst: uit.titels.prefix(3).joined(separator: " · "))
        }
    }

    /// De melding moet zeggen wat er is gebeurd. "3 wachten op je" terwijl ze er
    /// al in staan is niet alleen verwarrend, het is onwaar.
    private func kopVoorMelding(_ uit: Scanner.Uitkomst, _ zelf: ZelfGedaan) -> String {
        if zelf.erin > 0 {
            let erin = zelf.erin == 1 ? "1 ding erin gezet" : "\(zelf.erin) dingen erin gezet"
            guard zelf.blijftWachten > 0 else { return erin }
            return "\(erin), \(zelf.blijftWachten) wacht nog op je"
        }
        return uit.voorgesteld == 1
            ? "Er wacht iets op je"
            : "\(uit.voorgesteld) dingen wachten op je"
    }

    private struct ZelfGedaan {
        var erin = 0
        var blijftWachten = 0

        var staart: String {
            guard erin > 0 || blijftWachten > 0 else { return "" }
            var s = erin == 1 ? " 1 er zelf in gezet." : " \(erin) er zelf in gezet."
            if erin == 0 { s = "" }
            if blijftWachten > 0 {
                s += blijftWachten == 1
                    ? " 1 was niet zeker genoeg en wacht op jou."
                    : " \(blijftWachten) waren niet zeker genoeg en wachten op jou."
            }
            return s
        }
    }

    /// Zet er vanzelf in wat het model met "hoog" heeft bestempeld. De rest
    /// blijft gewoon wachten: de bedoeling is dat je minder hoeft na te lopen,
    /// niet dat je het niet meer kúnt.
    private func zetZelfIn(_ ids: [String]) async -> ZelfGedaan {
        var uitkomst = ZelfGedaan()
        for id in ids {
            guard let v = wachtrij.items.first(where: { $0.id == id }), v.status == .open else {
                continue
            }
            // Geen zekerheid opgegeven telt als niet zeker. Wie zwijgt, stemt
            // hier niet toe.
            guard v.zekerheid == "hoog" else {
                uitkomst.blijftWachten += 1
                continue
            }
            await keur(v, ja: true)
            // `keur` kan alsnog stuklopen of op "stond er al" uitkomen; alleen
            // wat echt is aangemaakt telt mee.
            if wachtrij.items.first(where: { $0.id == id })?.status == .goedgekeurd {
                uitkomst.erin += 1
            }
        }
        return uitkomst
    }

    // MARK: besluiten

    func keur(_ v: Voorstel, ja: Bool) async {
        guard ja else {
            wachtrij.werkBij(v.id) { $0.status = .geweigerd }
            return
        }
        guard let agenda else { return }
        do {
            let id: String
            if v.soort == .afspraak {
                guard let b = v.begin, let e = v.eind else { return }
                if await agenda.heeftAfspraak(titel: v.titel, begin: b) {
                    wachtrij.werkBij(v.id) { $0.status = .geweigerd; $0.fout = "stond er al" }
                    return
                }
                id = try await agenda.maakAfspraak(titel: v.titel, begin: b, eind: e,
                                                   locatie: v.locatie, notitie: v.notitie)
            } else {
                id = try await agenda.maakHerinnering(
                    wat: v.titel, uiterlijk: v.uiterlijk, notitie: v.notitie,
                    voorsprongDagen: instellingen.voorsprongDagen)
            }
            wachtrij.werkBij(v.id) { $0.status = .goedgekeurd; $0.itemId = id }
        } catch {
            wachtrij.werkBij(v.id) { $0.status = .mislukt; $0.fout = error.localizedDescription }
            melding = error.localizedDescription
        }
    }

    func draaiTerug(_ v: Voorstel) async {
        guard let agenda, !v.itemId.isEmpty else { return }
        do {
            if v.soort == .afspraak { try await agenda.verwijder(afspraakId: v.itemId) }
            else { try await agenda.verwijder(herinneringId: v.itemId) }
            wachtrij.werkBij(v.id) { $0.status = .geweigerd; $0.fout = "teruggedraaid" }
        } catch {
            melding = error.localizedDescription
        }
    }
}
