import Combine
import Foundation

/// Everything the app does, separated from wherever the request came from. The window and
/// the menu bar item both talk to this, which is why it no longer lives in the view: a run
/// in the background has no window at all.
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
        // The ticker follows the setting: change it and it moves along immediately.
        instellingen.$ritmeMinuten
            .removeDuplicates()
            .sink { [weak self] minuten in
                Task { @MainActor in self?.zetWekker(minuten) }
            }
            .store(in: &abonnementen)
    }

    /// Once at startup: request access and wind up the ticker.
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

    // MARK: scanning

    func kijkNa(vanzelf: Bool = false) async {
        guard !bezig else { return }

        // A run started by itself must not wake Mail: that would open an application you
        // had deliberately closed.
        if vanzelf && !Mail.draait {
            melding = t("run.mailNotRunning")
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

    /// The notification has to say what happened. "3 waiting for you" while they are
    /// already filed is not merely confusing, it is untrue.
    private func kopVoorMelding(_ uit: Scanner.Uitkomst, _ zelf: ZelfGedaan) -> String {
        if zelf.erin > 0 {
            let erin = zelf.erin == 1
                ? t("notify.filed.one")
                : String(format: t("notify.filed.many"), zelf.erin)
            guard zelf.blijftWachten > 0 else { return erin }
            return String(format: t("notify.filedAndWaiting"), erin, zelf.blijftWachten)
        }
        return uit.voorgesteld == 1
            ? t("notify.waiting.one")
            : String(format: t("notify.waiting.many"), uit.voorgesteld)
    }

    private struct ZelfGedaan {
        var erin = 0
        var blijftWachten = 0

        var staart: String {
            guard erin > 0 || blijftWachten > 0 else { return "" }
            var s = erin == 1
                ? t("tail.filed.one")
                : String(format: t("tail.filed.many"), erin)
            if erin == 0 { s = "" }
            if blijftWachten > 0 {
                s += blijftWachten == 1
                    ? t("tail.unsure.one")
                    : String(format: t("tail.unsure.many"), blijftWachten)
            }
            return s
        }
    }

    /// Files whatever the model marked as "hoog" by itself. The rest keeps waiting: the
    /// point is that you have less to go through, not that you no longer can.
    private func zetZelfIn(_ ids: [String]) async -> ZelfGedaan {
        var uitkomst = ZelfGedaan()
        for id in ids {
            guard let v = wachtrij.items.first(where: { $0.id == id }), v.status == .open else {
                continue
            }
            // No confidence given counts as not confident. Silence is not consent here.
            guard v.zekerheid == "hoog" else {
                uitkomst.blijftWachten += 1
                continue
            }
            await keur(v, ja: true)
            // `keur` can still fail or land on "already there"; only what was actually
            // created counts.
            if wachtrij.items.first(where: { $0.id == id })?.status == .goedgekeurd {
                uitkomst.erin += 1
            }
        }
        return uitkomst
    }

    // MARK: decisions

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
                    wachtrij.werkBij(v.id) { $0.status = .geweigerd; $0.fout = t("status.alreadyThere") }
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
            wachtrij.werkBij(v.id) { $0.status = .geweigerd; $0.fout = t("status.undone") }
        } catch {
            melding = error.localizedDescription
        }
    }
}
