import AppKit
import SwiftUI

@main
struct PresortApp: App {
    @StateObject private var kern = Kern()

    var body: some Scene {
        WindowGroup("Presort", id: Vensters.hoofd) {
            Hoofdvenster(kern: kern)
                .environmentObject(kern.instellingen)
                .environmentObject(kern.wachtrij)
                .frame(minWidth: 620, minHeight: 460)
        }
        .defaultSize(width: 780, height: 620)
        .commands { CommandGroup(replacing: .newItem) {} }

        // Zonder dit is "vanzelf nakijken" een belofte die alleen geldt zolang
        // het venster open staat. Het menubalk-item houdt de app in de lucht en
        // laat zien wat er ondertussen is binnengekomen.
        MenuBarExtra {
            Menubalk(kern: kern, wachtrij: kern.wachtrij, wekker: kern.wekker)
        } label: {
            MenubalkTeken(wachtrij: kern.wachtrij)
        }

        Settings {
            InstellingenVenster(herkenners: kern.herkenners)
                .environmentObject(kern.instellingen)
                .environmentObject(kern.wachtrij)
        }
    }
}

struct Hoofdvenster: View {
    @ObservedObject var kern: Kern
    @EnvironmentObject private var instellingen: Instellingen
    @EnvironmentObject private var wachtrij: Wachtrij
    @Environment(\.openWindow) private var openWindow

    private var melding: String { kern.melding }
    private var bezig: Bool { kern.bezig }

    var body: some View {
        VStack(spacing: 0) {
            balk
            Divider()
            inhoud
        }
        .task {
            Vensters.onthoud { openWindow(id: Vensters.hoofd) }
            await kern.begin()
        }
    }

    private var balk: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Presort").font(.system(size: 15, weight: .semibold))
                Text(melding.isEmpty
                     ? "\(wachtrij.open.count) wachten op je"
                     : melding)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if bezig { ProgressView().controlSize(.small) }
            Picker("", selection: Binding(
                get: { instellingen.periode },
                set: { instellingen.periode = $0 })) {
                ForEach(Terugkijken.allCases) { p in
                    Text(p.kort).tag(p)
                }
            }
            .labelsHidden()
            .frame(width: 118)
            .help("Hoe ver terug de app in je postvak kijkt")
            Button("Nu nakijken") { Task { await kern.kijkNa() } }
                .disabled(bezig || !instellingen.isIngericht)
            SettingsLink { Text("Instellingen") }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var inhoud: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !instellingen.isIngericht {
                    Uitleg()
                }

                Kop("Wacht op jou")
                if wachtrij.open.isEmpty {
                    Leeg("Niets open. Wat gevonden is, is afgehandeld.")
                }
                ForEach(wachtrij.open) { v in
                    VoorstelKaart(voorstel: v,
                                  goedkeuren: { Task { await kern.keur(v, ja: true) } },
                                  weigeren: { Task { await kern.keur(v, ja: false) } })
                }

                if !wachtrij.afgehandeld.isEmpty {
                    Kop("Afgehandeld")
                    ForEach(wachtrij.afgehandeld.prefix(12)) { v in
                        AfgehandeldRij(voorstel: v, terugdraaien: { Task { await kern.draaiTerug(v) } })
                    }
                }

                if !wachtrij.overgeslagen.isEmpty {
                    Kop("Niets in gevonden")
                    ForEach(wachtrij.overgeslagen.prefix(12)) { v in
                        HStack(alignment: .firstTextBaseline) {
                            Text(v.onderwerp).lineLimit(1)
                            Spacer(minLength: 12)
                            Text(v.reden).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 5)
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

}

// MARK: menubalk

/// Het teken in de menubalk. Vol bakje als er iets op je wacht, leeg bakje als
/// je bij bent -- dat is met een half oog te zien, een getal niet.
struct MenubalkTeken: View {
    @ObservedObject var wachtrij: Wachtrij

    var body: some View {
        let n = wachtrij.open.count
        Image(systemName: n == 0 ? "tray" : "tray.full.fill")
            .accessibilityLabel(n == 0 ? "Niets open" : "\(n) wachten op je")
    }
}

struct Menubalk: View {
    @ObservedObject var kern: Kern
    @ObservedObject var wachtrij: Wachtrij
    @ObservedObject var wekker: Wekker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(kopregel)

        if !wachtrij.open.isEmpty {
            Divider()
            // Twee klikken vanaf de menubalk, zonder het venster te openen:
            // voor het geval dat is de hele achtergrondlus bedoeld.
            ForEach(wachtrij.open.prefix(8)) { v in
                Menu(v.titel) {
                    Button("Zet het erin") { Task { await kern.keur(v, ja: true) } }
                    Button("Weg ermee") { Task { await kern.keur(v, ja: false) } }
                }
            }
        }

        Divider()
        Button("Nu nakijken") { Task { await kern.kijkNa() } }
            .disabled(kern.bezig || !kern.instellingen.isIngericht)
        Button("Open venster") {
            Vensters.onthoud { openWindow(id: Vensters.hoofd) }
            Vensters.naarVoren()
        }
        SettingsLink { Text("Instellingen…") }

        Divider()
        Button("Quit Presort") { NSApp.terminate(nil) }
    }

    private var kopregel: String {
        if kern.bezig { return "Bezig met nakijken…" }
        let n = wachtrij.open.count
        if n == 0 {
            guard let v = wekker.volgende else { return "Niets open" }
            return "Niets open · weer om \(Datums.klok(v))"
        }
        let wat = n == 1 ? "1 wacht op je" : "\(n) wachten op je"
        guard let v = wekker.volgende else { return wat }
        return "\(wat) · weer om \(Datums.klok(v))"
    }
}

// MARK: onderdelen

struct Kop: View {
    let tekst: String
    init(_ t: String) { tekst = t }
    var body: some View {
        Text(tekst.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }
}

struct Leeg: View {
    let tekst: String
    init(_ t: String) { tekst = t }
    var body: some View {
        Text(tekst).font(.system(size: 12)).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.vertical, 6)
    }
}

struct VoorstelKaart: View {
    let voorstel: Voorstel
    let goedkeuren: () -> Void
    let weigeren: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Liever de naam van het punt dat het vond dan de vorm: zo zie je
                // meteen welke instelling je moet bijstellen als het misgaat.
                Text(merk)
                    .font(.system(size: 9, weight: .semibold)).kerning(0.6)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(voorstel.soort == .afspraak
                                ? Color.accentColor.opacity(0.15) : Color.orange.opacity(0.16))
                    .foregroundStyle(voorstel.soort == .afspraak ? Color.accentColor : Color.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(voorstel.titel).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            }
            Voorbeeld(voorstel: voorstel)
            HStack(spacing: 8) {
                Button("Zet het erin", action: goedkeuren).buttonStyle(.borderedProminent)
                Button("Weg ermee", action: weigeren)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var merk: String {
        let naam = voorstel.herkenner ?? (voorstel.soort == .afspraak ? "Afspraak" : "Herinnering")
        return naam.uppercased()
    }
}

/// Laat zien wat er straks in de agenda of de lijst staat, veld voor veld, met
/// de woorden die er werkelijk in komen. Daarvóór toonde de kaart wat er uit de
/// mail was geplukt -- en dat is iets anders dan waar je ja tegen zegt.
struct Voorbeeld: View {
    let voorstel: Voorstel
    @EnvironmentObject private var instellingen: Instellingen

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(kop)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 3) {
                if voorstel.soort == .afspraak {
                    rij("Wanneer", Datums.reeks(voorstel.begin, voorstel.eind))
                    if !voorstel.locatie.isEmpty { rij("Waar", voorstel.locatie) }
                } else {
                    rij("Uiterlijk", voorstel.uiterlijk.map(Datums.lang) ?? "geen datum")
                    rij("Seintje", seintje)
                    if !voorstel.bedrag.isEmpty { rij("Bedrag", voorstel.bedrag) }
                }
                rij("Notitie", voorstel.notitie)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var kop: String {
        let naam = instellingen.agendaNaam
        return voorstel.soort == .afspraak
            ? "KOMT IN JE AGENDA ‘\(naam)’"
            : "KOMT IN JE LIJST ‘\(naam)’"
    }

    /// Dezelfde rekensom die `Agenda` straks doet, zodat hier niets staat wat
    /// daar niet gebeurt.
    private var seintje: String {
        guard voorstel.uiterlijk != nil else { return "geen, er is geen datum" }
        guard let wek = Datums.seintje(uiterlijk: voorstel.uiterlijk,
                                       voorsprongDagen: instellingen.voorsprongDagen) else {
            return instellingen.voorsprongDagen == 0
                ? "geen, je vroeg om geen voorsprong"
                : "geen, die datum is al geweest"
        }
        return "\(Datums.lang(wek))  (\(instellingen.voorsprongDagen) dagen eerder)"
    }

    private func rij(_ label: String, _ waarde: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .gridColumnAlignment(.leading)
                .frame(width: 62, alignment: .leading)
            Text(waarde.isEmpty ? "—" : waarde)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AfgehandeldRij: View {
    let voorstel: Voorstel
    let terugdraaien: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(voorstel.titel.isEmpty ? voorstel.onderwerp : voorstel.titel).lineLimit(1)
            Spacer(minLength: 8)
            Text(voorstel.fout.isEmpty ? voorstel.status.rawValue : voorstel.fout)
                .foregroundStyle(.tertiary).lineLimit(1)
            if voorstel.status == .goedgekeurd && !voorstel.itemId.isEmpty {
                Button("Terugdraaien", action: terugdraaien).controlSize(.mini)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }
}

struct Uitleg: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nog niet ingericht").font(.system(size: 13, weight: .semibold))
            Text("Presort talks to any model that speaks the OpenAI shape — Ollama on this "
                 + "Mac, een server bij je thuis, of een clouddienst. Vul bij Instellingen het "
                 + "adres en de naam van het model in.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

/// Tabbladen in plaats van één lange lijst: wat de app allemaal kan moet te
/// vinden zijn zonder scrollen, anders bestaat de helft van de instellingen
/// alleen op papier.
struct InstellingenVenster: View {
    @ObservedObject var herkenners: Herkenners

    var body: some View {
        TabView {
            ModelTabblad()
                .tabItem { Label("Model", systemImage: "cpu") }
            PostTabblad()
                .tabItem { Label("Post", systemImage: "envelope") }
            HerkennersTabblad(herkenners: herkenners)
                .tabItem { Label("Waar op gelet wordt", systemImage: "checklist") }
            VanzelfTabblad()
                .tabItem { Label("Vanzelf", systemImage: "clock") }
            AanmakenTabblad()
                .tabItem { Label("Aanmaken", systemImage: "calendar.badge.plus") }
        }
        .frame(width: 620, height: 480)
    }
}

struct VanzelfTabblad: View {
    @EnvironmentObject private var instellingen: Instellingen
    @State private var bijInloggen = false
    @State private var inlogFout = ""

    var body: some View {
        Form {
            Section {
                Picker("Kijk uit zichzelf", selection: Binding(
                    get: { instellingen.ritme },
                    set: { instellingen.ritme = $0 })) {
                    ForEach(Ritme.allCases) { r in
                        Text(r.naam).tag(r)
                    }
                }
                Toggle("Laat het weten als er iets gevonden is", isOn: $instellingen.meldingen)
                Toggle("Start bij inloggen", isOn: $bijInloggen)
                Text("De app blijft in de menubalk staan en kijkt op die tijden zelf na. "
                     + "Draait Mail op dat moment niet, dan slaat hij de beurt over — er "
                     + "wordt nooit iets voor je opgestart.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !inlogFout.isEmpty {
                    Text(inlogFout).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task { bijInloggen = Inloggen.isAan }
        .onChange(of: bijInloggen) { _, nieuw in
            guard nieuw != Inloggen.isAan else { return }
            inlogFout = Inloggen.zet(nieuw) ?? ""
            // Lukte het niet, dan mag het schakelaartje niet doen alsof van wel.
            bijInloggen = Inloggen.isAan
        }
        .onChange(of: instellingen.meldingen) { _, nieuw in
            if nieuw { Task { await Meldingen.vraagToestemming() } }
        }
    }
}

/// De lijst met punten waar de app op let, met de tekst erachter. Bewerkbaar is
/// alleen de omschrijving; de aanhef en het formulier staan er onbewerkbaar
/// omheen, zodat te zien is wat er werkelijk wordt gevraagd.
struct HerkennersTabblad: View {
    @ObservedObject var herkenners: Herkenners
    @State private var keuze: String?

    private var gekozen: Herkenner? { herkenners.alle.first { $0.id == keuze } }

    private func verwijderGekozen() {
        guard let h = gekozen, h.eigen else { return }
        herkenners.verwijder(h.id)
        keuze = herkenners.alle.first?.id
    }

    var body: some View {
        HStack(spacing: 0) {
            lijst.frame(width: 218)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { if keuze == nil { keuze = herkenners.alle.first?.id } }
    }

    private var lijst: some View {
        VStack(spacing: 0) {
            List(selection: $keuze) {
                ForEach(herkenners.alle) { h in
                    HStack(spacing: 7) {
                        Toggle("", isOn: Binding(get: { h.aan },
                                                 set: { herkenners.zet(h.id, aan: $0) }))
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 0) {
                            Text(h.naam).font(.system(size: 12, weight: .medium))
                            if !h.uitleg.isEmpty {
                                Text(h.uitleg).font(.system(size: 10))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .tag(h.id)
                    .contextMenu { rijContextmenu(h) }
                }
            }
            Divider()
            HStack(spacing: 2) {
                // Het klikvlak moet uit de label komen, niet uit het teken zelf:
                // een minteken is één punt hoog, en dat was precies zo groot als
                // het gebied waar je hem kon raken.
                Button { keuze = herkenners.voegToe().id } label: {
                    Image(systemName: "plus").tikvlak()
                }
                .help("Zelf een punt toevoegen")
                Button {
                    verwijderGekozen()
                } label: {
                    Image(systemName: "minus").tikvlak()
                }
                .disabled(gekozen?.eigen != true)
                .help("Alleen je eigen punten kun je weggooien")
                Spacer()
                Text("\(herkenners.actief.count) aan")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8).padding(.vertical, 5)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let h = gekozen {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    kop(h)

                    Text("Wat de app hierover tegen het model zegt")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    vast(Herkenner.aanhef)

                    TextEditor(text: Binding(
                        get: { herkenners.alle.first { $0.id == h.id }?.instructie ?? "" },
                        set: { herkenners.bewerk(h.id, instructie: $0) }))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 150)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor)))

                    vast("Antwoord uitsluitend met JSON, zonder uitleg:\n"
                         + h.schema + "\n\n" + Herkenner.slot)

                    Text("Het formulier staat vast en is niet te bewerken. Daar rekent de app "
                         + "op: titels worden op lengte gecontroleerd, datums op of ze niet "
                         + "verzonnen zijn. Wie het formulier mag herschrijven, schrijft die "
                         + "controle weg.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    knoppen(h)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Kies links een punt.")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func kop(_ h: Herkenner) -> some View {
        if h.eigen {
            // Eigen punten mag je helemaal zelf benoemen; de ingebouwde namen
            // zijn de woorden waarin de app over zichzelf praat.
            TextField("Naam", text: Binding(
                get: { herkenners.alle.first { $0.id == h.id }?.naam ?? "" },
                set: { herkenners.hernoem(h.id, naam: $0) }))
                .font(.system(size: 13, weight: .semibold))
            TextField("Korte uitleg", text: Binding(
                get: { herkenners.alle.first { $0.id == h.id }?.uitleg ?? "" },
                set: { herkenners.hernoem(h.id, uitleg: $0) }))
                .font(.system(size: 11))
            Picker("Wordt een", selection: Binding(
                get: { h.vorm },
                set: { herkenners.hernoem(h.id, vorm: $0) })) {
                ForEach(Herkenner.Vorm.allCases) { v in Text(v.naam).tag(v) }
            }
            .pickerStyle(.radioGroup)
        } else {
            Text(h.naam).font(.system(size: 14, weight: .semibold))
            Text("\(h.uitleg) · wordt een \(h.vorm.naam.lowercased())")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func knoppen(_ h: Herkenner) -> some View {
        HStack {
            if !h.eigen && herkenners.isAangepast(h.id) {
                Button("Herstel de standaardtekst") { herkenners.herstel(h.id) }
            }
            // Een knop van behoorlijk formaat, naast het mintekentje links: dat
            // is klein, en het is de enige plek waar weggooien kan.
            if h.eigen {
                Button("Verwijder dit punt", role: .destructive) { verwijderGekozen() }
            }
            Spacer()
            Text("Elk punt dat aan staat is één extra vraag per bericht.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .controlSize(.small)
        .padding(.top, 2)

        if !h.eigen {
            // Zonder deze zin lijkt de mintoets stuk: op een uitgeschakelde knop
            // laat macOS geen hulpballon zien.
            Text("Ingebouwde punten kun je uitzetten en herschrijven, maar niet weggooien.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func rijContextmenu(_ h: Herkenner) -> some View {
        Group {
            if h.eigen {
                Button("Verwijder ‘\(h.naam)’") {
                    herkenners.verwijder(h.id)
                    if keuze == h.id { keuze = herkenners.alle.first?.id }
                }
            }
        }
    }

    private func vast(_ tekst: String) -> some View {
        Text(tekst)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(7)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

extension View {
    /// Geeft een klein teken een klikvlak waar een muis op kan mikken. Zonder
    /// dit reikt het aanwijsbare gebied van een randloze knop tot precies aan de
    /// tekening: bij een minteken is dat één punt hoog.
    func tikvlak(breed: CGFloat = 24, hoog: CGFloat = 20) -> some View {
        frame(width: breed, height: hoog)
            .contentShape(Rectangle())
    }
}

struct ModelTabblad: View {
    @EnvironmentObject private var instellingen: Instellingen

    var body: some View {
        Form {
            Section {
                TextField("Adres", text: $instellingen.eindpunt,
                          prompt: Text("http://127.0.0.1:11434/v1"))
                TextField("Naam van het model", text: $instellingen.model,
                          prompt: Text("qwen3:8b"))
                SecureField("Sleutel (leeg mag)", text: $instellingen.sleutel)
                Text("Elk eindpunt dat de OpenAI-vorm spreekt werkt: Ollama, vLLM, LiteLLM "
                     + "of een clouddienst. Het model krijgt geen gereedschap in handen — "
                     + "alleen tekst erin, een formulier eruit.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PostTabblad: View {
    @EnvironmentObject private var instellingen: Instellingen
    @EnvironmentObject private var wachtrij: Wachtrij
    @State private var vraagtBevestiging = false

    var body: some View {
        Form {
            Section {
                TextField("Account in Mail", text: $instellingen.account)
                TextField("Postvak", text: $instellingen.postvak)
                Picker("Kijk terug", selection: Binding(
                    get: { instellingen.periode },
                    set: { instellingen.periode = $0 })) {
                    ForEach(Terugkijken.allCases) { p in
                        Text(p.naam).tag(p)
                    }
                }
                Text("Berichten die je al hebt gezien worden overgeslagen, dus een ruime "
                     + "periode kost alleen de eerste keer tijd.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section {
                Button("Kijk alle post opnieuw na…") { vraagtBevestiging = true }
                    .disabled(wachtrij.geziene.isEmpty)
                Text("De app slaat over wat hij al heeft nagekeken. Heb je bij ‘Waar op gelet "
                     + "wordt’ een omschrijving bijgesteld, dan merk je daar niets van tot er "
                     + "nieuwe post komt. Hiermee gaat alles opnieuw langs het model. "
                     + "\(wachtrij.geziene.count) berichten staan nu als nagekeken.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Alles opnieuw nakijken?", isPresented: $vraagtBevestiging) {
            Button("Opnieuw nakijken", role: .destructive) { wachtrij.vergeetGeziene() }
            Button("Laat maar", role: .cancel) {}
        } message: {
            Text("De volgende beurt gaat alle post uit de gekozen periode weer langs het "
                 + "model. Dat kost tijd, en je kunt voorstellen terugzien die je eerder al "
                 + "hebt weggestuurd. Wat er al staat blijft staan.")
        }
    }
}

struct AanmakenTabblad: View {
    @EnvironmentObject private var instellingen: Instellingen

    var body: some View {
        Form {
            Section {
                TextField("Eigen agenda en lijst", text: $instellingen.agendaNaam)
                Toggle("Alleen bij hoge zekerheid", isOn: $instellingen.alleenHogeZekerheid)
                Toggle("Zet ze er zelf in, zonder te vragen", isOn: $instellingen.zetZelfIn)
                Text("Uit: de app stelt voor en jij drukt op de knop. Aan: wat het model ‘hoog’ "
                     + "noemt gaat er meteen in, de rest blijft gewoon wachten. Het komt in je "
                     + "eigen agenda en lijst, en in ‘Afgehandeld’ staat bij elk ding een knop "
                     + "om het terug te draaien.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("Waarschuw me", selection: Binding(
                    get: { instellingen.voorsprong },
                    set: { instellingen.voorsprong = $0 })) {
                    ForEach(Voorsprong.allCases) { v in
                        Text(v.naam).tag(v)
                    }
                }
                Text("Bij een uiterste datum krijg je zoveel dagen ervoor een seintje. De "
                     + "herinnering houdt de echte datum — je wordt alleen eerder gepord, "
                     + "want op de laatste dag is iets terugsturen meestal niet meer te doen.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Wat de app aanmaakt komt in een eigen agenda en een eigen "
                     + "herinneringenlijst. Je bestaande agenda's worden gelezen maar nooit "
                     + "gewijzigd.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
