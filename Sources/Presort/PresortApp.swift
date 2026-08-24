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

        // Without this, "checking by itself" is a promise that only holds while the
        // window is open. The menu bar item keeps the app alive and shows what came in
        // while you were not looking.
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
                     ? String(format: t("window.waiting"), wachtrij.open.count)
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
            .help(t("toolbar.lookbackHelp"))
            Button(t("button.checkNow")) { Task { await kern.kijkNa() } }
                .disabled(bezig || !instellingen.isIngericht)
            SettingsLink { Text(t("button.settings")) }
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

                Kop(t("section.waiting"))
                if wachtrij.open.isEmpty {
                    Leeg(t("empty.waiting"))
                }
                ForEach(wachtrij.open) { v in
                    VoorstelKaart(voorstel: v,
                                  goedkeuren: { Task { await kern.keur(v, ja: true) } },
                                  weigeren: { Task { await kern.keur(v, ja: false) } })
                }

                if !wachtrij.afgehandeld.isEmpty {
                    Kop(t("section.handled"))
                    ForEach(wachtrij.afgehandeld.prefix(12)) { v in
                        AfgehandeldRij(voorstel: v, terugdraaien: { Task { await kern.draaiTerug(v) } })
                    }
                }

                if !wachtrij.overgeslagen.isEmpty {
                    Kop(t("section.skipped"))
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

/// The menu bar icon. A full tray when something is waiting, an empty one when you are
/// up to date -- readable out of the corner of your eye, which a number is not.
struct MenubalkTeken: View {
    @ObservedObject var wachtrij: Wachtrij

    var body: some View {
        let n = wachtrij.open.count
        Image(systemName: n == 0 ? "tray" : "tray.full.fill")
            .accessibilityLabel(n == 0 ? t("menu.nothingWaiting")
                                       : String(format: t("window.waiting"), n))
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
            // Two clicks from the menu bar without opening the window: that case is what
            // the whole background loop exists for.
            ForEach(wachtrij.open.prefix(8)) { v in
                Menu(v.titel) {
                    Button(t("button.fileIt")) { Task { await kern.keur(v, ja: true) } }
                    Button(t("button.discard")) { Task { await kern.keur(v, ja: false) } }
                }
            }
        }

        Divider()
        Button(t("button.checkNow")) { Task { await kern.kijkNa() } }
            .disabled(kern.bezig || !kern.instellingen.isIngericht)
        Button(t("menu.openWindow")) {
            Vensters.onthoud { openWindow(id: Vensters.hoofd) }
            Vensters.naarVoren()
        }
        SettingsLink { Text(t("menu.settings")) }

        Divider()
        Button(t("menu.quit")) { NSApp.terminate(nil) }
    }

    private var kopregel: String {
        if kern.bezig { return t("menu.checking") }
        let n = wachtrij.open.count
        let wat = n == 0
            ? t("menu.nothingWaiting")
            : (n == 1 ? t("menu.waiting.one") : String(format: t("window.waiting"), n))
        guard let v = wekker.volgende else { return wat }
        return String(format: t("menu.againAt"), wat, Datums.klok(v))
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
                // The name of the detector that found it, rather than the shape: that way
                // you see immediately which setting to adjust when it goes wrong.
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
                Button(t("button.fileIt"), action: goedkeuren).buttonStyle(.borderedProminent)
                Button(t("button.discard"), action: weigeren)
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
        let naam = voorstel.herkenner
            ?? (voorstel.soort == .afspraak ? t("badge.event") : t("badge.reminder"))
        return naam.uppercased()
    }
}

/// Shows what will end up in the calendar or the list, field by field, with
/// the words that will actually be written. Before this the card showed what had been
/// picked out of the mail -- which is a different thing from what you are agreeing to.
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
                    rij(t("card.when"), Datums.reeks(voorstel.begin, voorstel.eind))
                    if !voorstel.locatie.isEmpty { rij(t("card.where"), voorstel.locatie) }
                } else {
                    rij(t("card.due"), voorstel.uiterlijk.map(Datums.lang) ?? t("date.none"))
                    rij(t("card.alert"), seintje)
                    if !voorstel.bedrag.isEmpty { rij(t("card.amount"), voorstel.bedrag) }
                }
                rij(t("card.note"), voorstel.notitie)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var kop: String {
        let naam = instellingen.agendaNaam
        return String(format: t(voorstel.soort == .afspraak
                               ? "card.intoCalendar" : "card.intoList"), naam)
    }

    /// The same calculation `Agenda` will do later, so that nothing shown here fails to
    /// happen there.
    private var seintje: String {
        guard voorstel.uiterlijk != nil else { return t("alert.noneNoDate") }
        guard let wek = Datums.seintje(uiterlijk: voorstel.uiterlijk,
                                       voorsprongDagen: instellingen.voorsprongDagen) else {
            return t(instellingen.voorsprongDagen == 0
                     ? "alert.noneNoLead" : "alert.nonePassed")
        }
        return String(format: t("alert.at"), Datums.lang(wek), instellingen.voorsprongDagen)
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
            Text(voorstel.fout.isEmpty ? voorstel.status.getoond : voorstel.fout)
                .foregroundStyle(.tertiary).lineLimit(1)
            if voorstel.status == .goedgekeurd && !voorstel.itemId.isEmpty {
                Button(t("button.undo"), action: terugdraaien).controlSize(.mini)
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
            Text(t("setup.title")).font(.system(size: 13, weight: .semibold))
            Text(t("setup.body"))
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

/// Tabs rather than one long list: everything the app can do has to be findable without
/// scrolling, otherwise half the settings exist only on paper.
struct InstellingenVenster: View {
    @ObservedObject var herkenners: Herkenners

    var body: some View {
        TabView {
            ModelTabblad()
                .tabItem { Label(t("tab.model"), systemImage: "cpu") }
            PostTabblad()
                .tabItem { Label(t("tab.mail"), systemImage: "envelope") }
            HerkennersTabblad(herkenners: herkenners)
                .tabItem { Label(t("tab.watch"), systemImage: "checklist") }
            VanzelfTabblad()
                .tabItem { Label(t("tab.auto"), systemImage: "clock") }
            AanmakenTabblad()
                .tabItem { Label(t("tab.create"), systemImage: "calendar.badge.plus") }
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
                Picker(t("auto.rhythm"), selection: Binding(
                    get: { instellingen.ritme },
                    set: { instellingen.ritme = $0 })) {
                    ForEach(Ritme.allCases) { r in
                        Text(r.naam).tag(r)
                    }
                }
                Toggle(t("auto.notify"), isOn: $instellingen.meldingen)
                Toggle(t("auto.login"), isOn: $bijInloggen)
                Text(t("auto.note"))
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
            // If it failed, the switch must not pretend otherwise.
            bijInloggen = Inloggen.isAan
        }
        .onChange(of: instellingen.meldingen) { _, nieuw in
            if nieuw { Task { await Meldingen.vraagToestemming() } }
        }
    }
}

/// The list of points the app watches for, with the text behind each. Editable is
/// only the description; the preamble and the form sit around it, uneditable, so that
/// what is really being asked stays visible.
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
                // The hit area has to come from the label, not from the glyph: a minus
                // sign is one point tall, and that was exactly the size of the region you
                // could actually hit.
                Button { keuze = herkenners.voegToe().id } label: {
                    Image(systemName: "plus").tikvlak()
                }
                .help(t("detectors.add"))
                Button {
                    verwijderGekozen()
                } label: {
                    Image(systemName: "minus").tikvlak()
                }
                .disabled(gekozen?.eigen != true)
                .help(t("detectors.removeOnlyOwn"))
                Spacer()
                Text(String(format: t("detectors.onCount"), herkenners.actief.count))
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

                    Text(t("detectors.promptHeading"))
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

                    vast(t("prompt.reply") + "\n" + h.schema + "\n\n" + Herkenner.slot)

                    Text(t("detectors.formNote"))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    knoppen(h)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(t("detectors.pickOne"))
                .font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func kop(_ h: Herkenner) -> some View {
        if h.eigen {
            // Your own points you may name entirely yourself; the built-in names
            // are the words in which the app talks about itself.
            TextField(t("detectors.nameField"), text: Binding(
                get: { herkenners.alle.first { $0.id == h.id }?.naam ?? "" },
                set: { herkenners.hernoem(h.id, naam: $0) }))
                .font(.system(size: 13, weight: .semibold))
            TextField(t("detectors.summaryField"), text: Binding(
                get: { herkenners.alle.first { $0.id == h.id }?.uitleg ?? "" },
                set: { herkenners.hernoem(h.id, uitleg: $0) }))
                .font(.system(size: 11))
            Picker(t("detectors.becomes"), selection: Binding(
                get: { h.vorm },
                set: { herkenners.hernoem(h.id, vorm: $0) })) {
                ForEach(Herkenner.Vorm.allCases) { v in Text(v.naam).tag(v) }
            }
            .pickerStyle(.radioGroup)
        } else {
            Text(h.naam).font(.system(size: 14, weight: .semibold))
            Text(String(format: t("detectors.builtinSub"), h.uitleg, h.vorm.naam.lowercased()))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func knoppen(_ h: Herkenner) -> some View {
        HStack {
            if !h.eigen && herkenners.isAangepast(h.id) {
                Button(t("detectors.restore")) { herkenners.herstel(h.id) }
            }
            // A button of decent size, next to the small minus on the left: that one is
            // tiny, and it is the only place where removing is possible.
            if h.eigen {
                Button(t("detectors.remove"), role: .destructive) { verwijderGekozen() }
            }
            Spacer()
            Text(t("detectors.costNote"))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .controlSize(.small)
        .padding(.top, 2)

        if !h.eigen {
            // Without this sentence the minus button looks broken: macOS shows no tooltip
            // on a disabled control.
            Text(t("detectors.builtinNote"))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func rijContextmenu(_ h: Herkenner) -> some View {
        Group {
            if h.eigen {
                Button(String(format: t("detectors.removeNamed"), h.naam)) {
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
    /// Gives a small glyph a hit area a mouse can aim at. Without this, the clickable
    /// region of a borderless button reaches exactly as far as the drawing: for a minus
    /// sign that is one point tall.
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
                TextField(t("model.address"), text: $instellingen.eindpunt,
                          prompt: Text("http://127.0.0.1:11434/v1"))
                TextField(t("model.name"), text: $instellingen.model,
                          prompt: Text("qwen3:8b"))
                SecureField(t("model.key"), text: $instellingen.sleutel)
                Text(t("model.note"))
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
                TextField(t("mail.account"), text: $instellingen.account)
                TextField(t("mail.mailbox"), text: $instellingen.postvak)
                Picker(t("mail.lookback"), selection: Binding(
                    get: { instellingen.periode },
                    set: { instellingen.periode = $0 })) {
                    ForEach(Terugkijken.allCases) { p in
                        Text(p.naam).tag(p)
                    }
                }
                Text(t("mail.lookbackNote"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section {
                Button(t("mail.recheck")) { vraagtBevestiging = true }
                    .disabled(wachtrij.geziene.isEmpty)
                Text(String(format: t("mail.recheckNote"), wachtrij.geziene.count))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(t("mail.recheckTitle"), isPresented: $vraagtBevestiging) {
            Button(t("mail.recheckConfirm"), role: .destructive) { wachtrij.vergeetGeziene() }
            Button(t("mail.recheckCancel"), role: .cancel) {}
        } message: {
            Text(t("mail.recheckMessage"))
        }
    }
}

struct AanmakenTabblad: View {
    @EnvironmentObject private var instellingen: Instellingen

    var body: some View {
        Form {
            Section {
                TextField(t("create.calendarName"), text: $instellingen.agendaNaam)
                Toggle(t("create.onlyHigh"), isOn: $instellingen.alleenHogeZekerheid)
                Toggle(t("create.auto"), isOn: $instellingen.zetZelfIn)
                Text(t("create.autoNote"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Picker(t("create.warnMe"), selection: Binding(
                    get: { instellingen.voorsprong },
                    set: { instellingen.voorsprong = $0 })) {
                    ForEach(Voorsprong.allCases) { v in
                        Text(v.naam).tag(v)
                    }
                }
                Text(t("create.warnNote"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(t("create.scopeNote"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
