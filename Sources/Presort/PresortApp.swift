import AppKit
import SwiftUI

@main
struct PresortApp: App {
    @StateObject private var core = Core()

    var body: some Scene {
        WindowGroup("Presort", id: Windows.main) {
            MainWindow(core: core)
                .environmentObject(core.preferences)
                .environmentObject(core.queue)
                .frame(minWidth: 620, minHeight: 460)
        }
        .defaultSize(width: 780, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {}
            HelpCommands(core: core)
        }

        // Without this, "checking by itself" is a promise that only holds while the
        // window is open. The menu bar item keeps the app alive and shows what came in
        // while you were not looking.
        MenuBarExtra {
            MenuBarMenu(core: core, queue: core.queue, alarm: core.alarm)
        } label: {
            MenuBarIcon(queue: core.queue)
        }

        Settings {
            PreferencesWindow(detectors: core.detectors)
                .environmentObject(core.preferences)
                .environmentObject(core.queue)
                .environmentObject(core)
        }
    }
}

/// The Help menu, in a type of its own so it can reach `openWindow`.
///
/// Going through a stored closure was the old way and it had a hole: the closure was
/// installed by the window, so with no window there was nothing to call, and the menu item
/// whose whole job is to bring a window back did nothing at all.
struct HelpCommands: Commands {
    @ObservedObject var core: Core
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(t("welcome.menuItem")) {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: Windows.main)
                core.showWelcome = true
            }
        }
    }
}

struct MainWindow: View {
    @ObservedObject var core: Core
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var queue: Queue
    @Environment(\.openWindow) private var openWindow

    private var statusLine: String { core.statusLine }
    private var busy: Bool { core.busy }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            content
        }
        .task {
            Windows.remember { openWindow(id: Windows.main) }
            await core.start()
        }
        .sheet(isPresented: $core.showWelcome) {
            Welcome(done: {
                core.showWelcome = false
                preferences.hasSeenWelcome = true
            }, openSettings: {
                // The one thing that has to happen before the app is of any use: an address
                // and a model name. Sending them straight there beats saying "go to Settings".
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            })
        }
    }

    private var bar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Presort").font(.system(size: 15, weight: .semibold))
                Text(statusLine.isEmpty
                     ? String(format: t("window.waiting"), queue.waiting.count)
                     : statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Picker("", selection: Binding(
                get: { preferences.period },
                set: { preferences.period = $0 })) {
                ForEach(LookBack.allCases) { p in
                    Text(p.short).tag(p)
                }
            }
            .labelsHidden()
            .frame(width: 118)
            .help(t("toolbar.lookbackHelp"))
            Button(t("button.checkNow")) { Task { await core.check() } }
                .disabled(busy || !preferences.isConfigured)
            SettingsLink { Text(t("button.settings")) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !preferences.isConfigured {
                    SetupNote()
                } else if let problem = core.modelProblem {
                    ModelProblemNote(text: problem)
                }

                SectionHeading(t("section.waiting"))
                if queue.waiting.isEmpty {
                    EmptyNote(t("empty.waiting"))
                }
                ForEach(queue.waiting) { v in
                    ProposalCard(proposal: v,
                                  approve: { Task { await core.decide(v, yes: true) } },
                                  reject: { Task { await core.decide(v, yes: false) } })
                }

                if !queue.handled.isEmpty {
                    SectionHeading(t("section.handled"))
                    ForEach(queue.handled.prefix(12)) { v in
                        HandledRow(proposal: v, undoAction: { Task { await core.undo(v) } })
                    }
                }

                if !queue.skipped.isEmpty {
                    SectionHeading(t("section.skipped"))
                    ForEach(queue.skipped.prefix(12)) { v in
                        HStack(alignment: .firstTextBaseline) {
                            Text(v.subject).lineLimit(1)
                            Spacer(minLength: 12)
                            Text(v.reasonText).foregroundStyle(.tertiary).lineLimit(1)
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

// MARK: the menu bar

/// The menu bar icon. A full tray when something is waiting, an empty one when you are
/// up to date -- readable out of the corner of your eye, which a number is not.
struct MenuBarIcon: View {
    @ObservedObject var queue: Queue
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let n = queue.waiting.count
        Image(systemName: n == 0 ? "tray" : "tray.full.fill")
            // The icon is the one thing that is always there, so this is where the app
            // learns how to open its window. It used to be learned from the window itself,
            // which works right up until there is no window -- and then the menu item that
            // exists to bring one back quietly does nothing.
            .task { Windows.remember { openWindow(id: Windows.main) } }
            .accessibilityLabel(n == 0 ? t("menu.nothingWaiting")
                                       : String(format: t("window.waiting"), n))
    }
}

struct MenuBarMenu: View {
    @ObservedObject var core: Core
    @ObservedObject var queue: Queue
    @ObservedObject var alarm: Alarm
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(headingLine)

        if !queue.waiting.isEmpty {
            Divider()
            // Two clicks from the menu bar without opening the window: that case is what
            // the whole background loop exists for.
            ForEach(queue.waiting.prefix(8)) { v in
                Menu(v.title) {
                    Button(t("button.fileIt")) { Task { await core.decide(v, yes: true) } }
                    Button(t("button.discard")) { Task { await core.decide(v, yes: false) } }
                }
            }
        }

        Divider()
        Button(t("button.checkNow")) { Task { await core.check() } }
            .disabled(core.busy || !core.preferences.isConfigured)
        Button(t("menu.openWindow")) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: Windows.main)
        }
        SettingsLink { Text(t("menu.settings")) }

        Divider()
        Button(t("menu.quit")) { NSApp.terminate(nil) }
    }

    private var headingLine: String {
        if core.busy { return t("menu.checking") }
        let n = queue.waiting.count
        let what = n == 0
            ? t("menu.nothingWaiting")
            : (n == 1 ? t("menu.waiting.one") : String(format: t("window.waiting"), n))
        guard let v = alarm.next else { return what }
        return String(format: t("menu.againAt"), what, Dates.clock(v))
    }
}

// MARK: building blocks

struct SectionHeading: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }
}

struct EmptyNote: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.vertical, 6)
    }
}

struct ProposalCard: View {
    let proposal: Proposal
    let approve: () -> Void
    let reject: () -> Void
    @EnvironmentObject private var preferences: Preferences
    /// Parcel's carriers, for a parcel's card. Empty for everything else.
    @State private var carriers: [ParcelApp.Carrier] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // The name of the detector that found it, rather than the shape: that way
                // you see immediately which setting to adjust when it goes wrong.
                Text(badge)
                    .font(.system(size: 9, weight: .semibold)).kerning(0.6)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(tint.opacity(0.15))
                    .foregroundStyle(tint)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(proposal.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            }
            WhatLands(proposal: proposal, carriers: carriers)
            HStack(spacing: 8) {
                Button(t("button.fileIt"), action: approve).buttonStyle(.borderedProminent)
                    .disabled(!canFile)
                Button(t("button.discard"), action: reject)
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
        .task(id: proposal.id) {
            if proposal.category == .parcel { carriers = await ParcelCarriers.shared.all() }
        }
    }

    /// A parcel for Parcel needs a carrier Parcel knows, and without Parcel it needs a day for
    /// its reminder. Filing without would spend a request on a refusal, or do nothing at all.
    private var canFile: Bool {
        guard proposal.category == .parcel else { return true }
        guard preferences.parcelOn else { return proposal.dueDate != nil }
        return carriers.isEmpty
            || ParcelApp.carrier(for: proposal, among: carriers, region: ParcelApp.macRegion) != nil
    }

    private var badge: String {
        let name = proposal.detector ?? {
            switch proposal.category {
            case .event: return t("badge.event")
            case .document: return t("badge.document")
            case .parcel: return t("badge.parcel")
            default: return t("badge.reminder")
            }
        }()
        return name.uppercased()
    }

    private var tint: Color { proposal.category.tint }
}

/// Shows what will end up in the calendar or the list, field by field, with
/// the words that will actually be written. Before this the card showed what had been
/// picked out of the mail -- which is a different thing from what you are agreeing to.
struct WhatLands: View {
    let proposal: Proposal
    var carriers: [ParcelApp.Carrier] = []
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var queue: Queue

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(heading)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 3) {
                if proposal.category == .document {
                    row(t("card.file"), proposal.attachmentName ?? "")
                    row(t("card.documentDate"), proposal.dueDate.map(Dates.longDay)
                                                ?? t("card.dateOfMail"))
                    row(t("card.from"), proposal.correspondent ?? proposal.sender)
                    row(t("card.tags"), (proposal.keywords ?? []).joined(separator: ", "))
                } else if proposal.category == .parcel {
                    row(t("card.tracking"), proposal.trackingNumber ?? "")
                    if preferences.parcelOn && !carriers.isEmpty {
                        carrierRow
                    } else {
                        row(t("card.carrier"), proposal.carrier ?? "")
                    }
                    row(t("card.arrives"), proposal.dueDate.map(Dates.longDay) ?? t("card.arrivesUnknown"))
                } else if proposal.category == .event {
                    row(t("card.when"), Dates.spanText(proposal.start, proposal.end))
                    if !proposal.location.isEmpty { row(t("card.where"), proposal.location) }
                } else {
                    row(t("card.due"), proposal.dueDate.map(Dates.long) ?? t("date.none"))
                    row(t("card.alert"), alert)
                    if !proposal.amount.isEmpty { row(t("card.amount"), proposal.amount) }
                }
                if proposal.category != .document && proposal.category != .parcel {
                    row(t("card.note"), proposal.note)
                }
            }
            if proposal.category == .document {
                Text(t("card.paperlessNote"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if proposal.category == .parcel {
                Text(parcelNote)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var heading: String {
        switch proposal.category {
        case .document:
            return t("card.intoPaperless")
        case .parcel:
            return preferences.parcelOn
                ? t("card.intoParcel")
                : String(format: t("card.intoList"), preferences.calendarName)
        case .event:
            return String(format: t("card.intoCalendar"), preferences.calendarName)
        default:
            return String(format: t("card.intoList"), preferences.calendarName)
        }
    }

    /// The same calculation `CalendarStore` will do later, so that nothing shown here fails to
    /// happen there.
    private var alert: String {
        guard proposal.dueDate != nil else { return t("alert.noneNoDate") }
        guard let wake = Dates.alert(dueDate: proposal.dueDate,
                                       leadDays: preferences.leadDays) else {
            return t(preferences.leadDays == 0
                     ? "alert.noneNoLead" : "alert.nonePassed")
        }
        return String(format: t("alert.at"), Dates.long(wake), preferences.leadDays)
    }

    /// The carrier as a choice: the one matched from the mail when that worked, otherwise
    /// every carrier Parcel knows, with what the mail said as the prompt.
    private var carrierRow: some View {
        GridRow {
            Text(t("card.carrier"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .gridColumnAlignment(.leading)
                .frame(width: 62, alignment: .leading)
            Picker("", selection: Binding(
                get: {
                    ParcelApp.carrier(for: proposal, among: carriers, region: ParcelApp.macRegion)?.code ?? ""
                },
                set: { code in
                    queue.update(proposal.id) { $0.carrierCode = code.isEmpty ? nil : code }
                })) {
                Text(proposal.carrier.map { String(format: t("card.carrierPick"), $0) }
                     ?? t("card.carrierPickNone")).tag("")
                ForEach(carriers) { c in Text(c.name).tag(c.code) }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 260, alignment: .leading)
        }
    }

    private var parcelNote: String {
        if proposal.dueDate == nil && !preferences.parcelOn { return t("card.parcelNothing") }
        var s = t(proposal.dueDate == nil ? "card.parcelNoDay" : "card.parcelReminder")
        if preferences.parcelOn {
            s += " " + String(format: t("card.parcelQuota"), ParcelQuota().used(), ParcelApp.dailyLimit)
        }
        return s
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .gridColumnAlignment(.leading)
                .frame(width: 62, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HandledRow: View {
    let proposal: Proposal
    let undoAction: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The colour carries the shape, so a glance down the list separates
            // appointments from tasks from documents without reading a word. Dimmed when
            // nothing was created: a discarded row should not look like a filed one.
            Circle()
                .fill(proposal.category.tint.opacity(proposal.status == .filed ? 1 : 0.28))
                .frame(width: 6, height: 6)
                .padding(.trailing, 2)
            Text(proposal.title.isEmpty ? proposal.subject : proposal.title).lineLimit(1)
            Spacer(minLength: 8)
            Text(outcome)
                .foregroundStyle(proposal.status == .failed ? Color.orange : Color.secondary)
                .lineLimit(1)
            // Not for parcels: Parcel has no way to take a delivery back.
            if proposal.status == .filed && !proposal.itemId.isEmpty && proposal.category != .parcel {
                Button(t("button.undo"), action: undoAction).controlSize(.mini)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    /// What actually became of it. "Filed" says a decision was taken and nothing about
    /// where to go looking; a reminder in a list and a document in an archive are found in
    /// very different places.
    private var outcome: String {
        switch proposal.status {
        case .filed:     return proposal.category == .parcel ? parcelLanded : proposal.category.landed
        case .discarded: return proposal.error.isEmpty
                                ? t("status.discarded") : proposal.errorText
        case .failed:    return proposal.error.isEmpty
                                ? t("status.failed") : proposal.errorText
        case .waiting:   return t("status.waiting")
        }
    }

    /// A parcel can have gone to Parcel, into your reminders, or both.
    private var parcelLanded: String {
        guard ParcelFiling.inParcel(proposal.itemId) else { return t("outcome.reminder") }
        return t(ParcelFiling.reminderId(in: proposal.itemId) == nil
                 ? "outcome.parcel" : "outcome.parcelAndReminder")
    }
}

extension Proposal.Category {
    /// One colour per shape, used on the card and in the handled list alike -- the same
    /// thing should not be blue in one place and orange in another.
    var tint: Color {
        switch self {
        case .event:    return .accentColor
        case .document: return .purple
        case .parcel:   return .teal
        case .reminder: return .orange
        case .skipped:  return .gray
        }
    }

    /// Where something of this shape ends up, in words.
    var landed: String {
        switch self {
        case .event:    return t("outcome.event")
        case .reminder: return t("outcome.reminder")
        case .document: return t("outcome.document")
        case .parcel:   return t("outcome.parcel")
        case .skipped:  return ""
        }
    }
}

struct SetupNote: View {
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

/// Said once, above the queue, when the model cannot do the work: then nothing is being found
/// at all, and that deserves more than a line in the status bar.
struct ModelProblemNote: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t("modelcheck.problem.title")).font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsLink { Text(t("modelcheck.openSettings")) }
                .controlSize(.small)
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
struct PreferencesWindow: View {
    @ObservedObject var detectors: Detectors

    var body: some View {
        TabView {
            ModelTab()
                .tabItem { Label(t("tab.model"), systemImage: "cpu") }
            MailTab()
                .tabItem { Label(t("tab.mail"), systemImage: "envelope") }
            DetectorsTab(detectors: detectors)
                .tabItem { Label(t("tab.watch"), systemImage: "checklist") }
            AutomaticTab()
                .tabItem { Label(t("tab.auto"), systemImage: "clock") }
            CreatingTab()
                .tabItem { Label(t("tab.create"), systemImage: "calendar.badge.plus") }
            ConnectionsTab()
                .tabItem { Label(t("tab.connections"), systemImage: "app.connected.to.app.below.fill") }
        }
        .frame(width: 620, height: 480)
    }
}

struct AutomaticTab: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var atLogin = false
    @State private var loginError = ""

    var body: some View {
        Form {
            Section {
                Picker(t("auto.rhythm"), selection: Binding(
                    get: { preferences.rhythm },
                    set: { preferences.rhythm = $0 })) {
                    ForEach(Rhythm.allCases) { r in
                        Text(r.name).tag(r)
                    }
                }
                Toggle(t("auto.notify"), isOn: $preferences.notificationsOn)
                Toggle(t("auto.login"), isOn: $atLogin)
                Text(t("auto.note"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !loginError.isEmpty {
                    Text(loginError).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task { atLogin = LoginItem.isEnabled }
        .onChange(of: atLogin) { _, new in
            guard new != LoginItem.isEnabled else { return }
            loginError = LoginItem.set(new) ?? ""
            // If it failed, the switch must not pretend otherwise.
            atLogin = LoginItem.isEnabled
        }
        .onChange(of: preferences.notificationsOn) { _, new in
            if new { Task { await Notifier.askPermission() } }
        }
    }
}

/// The list of points the app watches for, with the text behind each. Editable is
/// only the description; the preamble and the form sit around it, uneditable, so that
/// what is really being asked stays visible.
struct DetectorsTab: View {
    @ObservedObject var detectors: Detectors
    @State private var choice: String?

    private var selected: Detector? { detectors.all.first { $0.id == choice } }

    private func removeSelected() {
        guard let h = selected, h.own else { return }
        detectors.remove(h.id)
        choice = detectors.all.first?.id
    }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 218)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { if choice == nil { choice = detectors.all.first?.id } }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $choice) {
                ForEach(detectors.all) { h in
                    HStack(spacing: 7) {
                        Toggle("", isOn: Binding(get: { h.enabled },
                                                 set: { detectors.set(h.id, enabled: $0) }))
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 0) {
                            Text(h.name).font(.system(size: 12, weight: .medium))
                            if !h.summary.isEmpty {
                                Text(h.summary).font(.system(size: 10))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .tag(h.id)
                    .contextMenu { rowContextMenu(h) }
                }
            }
            Divider()
            HStack(spacing: 2) {
                // The hit area has to come from the label, not from the glyph: a minus
                // sign is one point tall, and that was exactly the size of the region you
                // could actually hit.
                Button { choice = detectors.add().id } label: {
                    Image(systemName: "plus").hitArea()
                }
                .help(t("detectors.add"))
                Button {
                    removeSelected()
                } label: {
                    Image(systemName: "minus").hitArea()
                }
                .disabled(selected?.own != true)
                .help(t("detectors.removeOnlyOwn"))
                Spacer()
                Text(String(format: t("detectors.onCount"), detectors.active.count))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8).padding(.vertical, 5)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let h = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    heading(h)

                    Text(t("detectors.promptHeading"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    fixed(Detector.preamble)

                    TextEditor(text: Binding(
                        get: { detectors.all.first { $0.id == h.id }?.instruction ?? "" },
                        set: { detectors.edit(h.id, instruction: $0) }))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 150)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor)))

                    fixed(t("prompt.reply") + "\n" + h.schema + "\n\n" + Detector.closing)

                    Text(t("detectors.formNote"))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    buttons(h)
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
    private func heading(_ h: Detector) -> some View {
        if h.own {
            // Your own points you may name entirely yourself; the built-in names
            // are the words in which the app talks about itself.
            TextField(t("detectors.nameField"), text: Binding(
                get: { detectors.all.first { $0.id == h.id }?.name ?? "" },
                set: { detectors.rename(h.id, name: $0) }))
                .font(.system(size: 13, weight: .semibold))
            TextField(t("detectors.summaryField"), text: Binding(
                get: { detectors.all.first { $0.id == h.id }?.summary ?? "" },
                set: { detectors.rename(h.id, summary: $0) }))
                .font(.system(size: 11))
            Picker(t("detectors.becomes"), selection: Binding(
                get: { h.kind },
                set: { detectors.rename(h.id, kind: $0) })) {
                ForEach(Detector.Kind.allCases) { v in Text(v.name).tag(v) }
            }
            .pickerStyle(.radioGroup)
        } else {
            Text(h.name).font(.system(size: 14, weight: .semibold))
            Text(String(format: t("detectors.builtinSub"), h.summary, h.kind.name.lowercased()))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func buttons(_ h: Detector) -> some View {
        HStack {
            if !h.own && detectors.isEdited(h.id) {
                Button(t("detectors.restore")) { detectors.restore(h.id) }
            }
            // A button of decent size, next to the small minus on the left: that one is
            // tiny, and it is the only place where removing is possible.
            if h.own {
                Button(t("detectors.remove"), role: .destructive) { removeSelected() }
            }
            Spacer()
            Text(t("detectors.costNote"))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .controlSize(.small)
        .padding(.top, 2)

        if !h.own {
            // Without this sentence the minus button looks broken: macOS shows no tooltip
            // on a disabled control.
            Text(t("detectors.builtinNote"))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func rowContextMenu(_ h: Detector) -> some View {
        Group {
            if h.own {
                Button(String(format: t("detectors.removeNamed"), h.name)) {
                    detectors.remove(h.id)
                    if choice == h.id { choice = detectors.all.first?.id }
                }
            }
        }
    }

    private func fixed(_ text: String) -> some View {
        Text(text)
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
    func hitArea(wide: CGFloat = 24, tall: CGFloat = 20) -> some View {
        frame(width: wide, height: tall)
            .contentShape(Rectangle())
    }
}

struct ModelTab: View {
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var core: Core
    @State private var found: [String] = []
    @State private var asking = false
    @State private var note = ""
    @State private var testing = false
    @State private var progress = ""
    /// In the order they were tested, so the list does not jump around while it fills.
    @State private var tested: [String] = []
    @State private var results: [String: ModelClient.Check] = [:]
    @State private var skipped: Set<String> = []

    var body: some View {
        Form {
            Section {
                TextField(t("model.address"), text: $preferences.endpoint,
                          prompt: Text("http://127.0.0.1:11434/v1"))
                SecureField(t("model.key"), text: $preferences.key)

                // The field stays, always. Not every endpoint lists what it serves, and the
                // one that does may be down at the moment you are setting this up -- a
                // dropdown as the only way in would make the app unconfigurable.
                TextField(t("model.name"), text: $preferences.model,
                          prompt: Text("qwen3:8b"))

                if !found.isEmpty {
                    Picker(t("model.detected"), selection: pick) {
                        Text(t("model.pickPrompt")).tag("")
                        ForEach(found, id: \.self) { Text($0).tag($0) }
                    }
                }

                HStack(spacing: 8) {
                    Button(t("model.detect")) { Task { await detect() } }
                        .disabled(asking || preferences.endpoint
                            .trimmingCharacters(in: .whitespaces).isEmpty)
                    if asking { ProgressView().controlSize(.small) }
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .controlSize(.small)

                Text(t("model.note"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 8) {
                    Button(t("modelcheck.testOne")) { Task { await test([preferences.model]) } }
                        .disabled(testing || !preferences.isConfigured)
                    Button(t("modelcheck.testAll")) { Task { await test(found) } }
                        .disabled(testing || found.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    Text(progress).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .controlSize(.small)

                ForEach(tested, id: \.self) { name in resultRow(name) }

                Toggle(t("model.thinkingOff"), isOn: Binding(
                    get: { preferences.thinkingOff },
                    set: { preferences.setThinkingOff($0, for: preferences.model) }))
                    .disabled(preferences.model.trimmingCharacters(in: .whitespaces).isEmpty)
                Text(t("model.thinkingOffNote"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(t("modelcheck.note"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task(id: preferences.endpoint + "|" + preferences.key) {
            // Debounced: the address changes on every keystroke, and every attempt is a
            // request to somebody's machine. `task(id:)` cancels the pending one for us.
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await detect()
        }
    }

    /// One question per model, one model at a time: a server on your own network asked about
    /// nine models at once answers none of them quickly.
    private func test(_ names: [String]) async {
        let list = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !list.isEmpty else { return }
        testing = true
        defer { testing = false; progress = "" }
        for (i, name) in list.enumerated() {
            if !tested.contains(name) { tested.append(name) }
            // Embedding, speech and the like cannot hold a conversation; asking them is a
            // request wasted, and on a hosted service one paid for.
            if ModelTab.notForChat(name) {
                skipped.insert(name)
                continue
            }
            progress = String(format: t("modelcheck.progress"), i + 1, list.count)
            let client = ModelClient(endpoint: preferences.endpoint, key: preferences.key, model: name)
            let result = await client.check(startingWith: preferences.modelsWithoutThinking.contains(name))
            results[name] = result
            core.adopt(result, for: name)
        }
    }

    private static func notForChat(_ name: String) -> Bool {
        name.range(of: "embed|stt|tts|whisper|rerank|speech|transcri",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Choosing a model that only works with thinking off brings that setting along.
    private func use(_ name: String) {
        if results[name]?.health == .needsThinkingOff { preferences.setThinkingOff(true, for: name) }
        preferences.model = name
    }

    private func resultRow(_ name: String) -> some View {
        let result = results[name]
        let usable = result?.usable ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: result == nil ? "minus.circle"
                  : usable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result == nil ? Color.secondary : usable ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .medium))
                Text(result?.sentence ?? (skipped.contains(name) ? t("modelcheck.skipped") : "…"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if usable {
                if name == preferences.model {
                    Text(t("modelcheck.inUse")).font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Button(t("modelcheck.use")) { use(name) }.controlSize(.small)
                }
            }
        }
    }

    /// Selecting from the list types into the field; the field remains the stored value.
    /// An empty tag covers "what is filled in is not one of these", which is a normal state
    /// rather than a mistake -- LiteLLM aliases, for instance, come and go.
    private var pick: Binding<String> {
        Binding(get: { found.contains(preferences.model) ? preferences.model : "" },
                set: { if !$0.isEmpty { preferences.model = $0 } })
    }

    private func detect() async {
        let address = preferences.endpoint.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { found = []; note = ""; return }
        asking = true
        defer { asking = false }
        let client = ModelClient(endpoint: address, key: preferences.key, model: "")
        do {
            let list = try await client.availableModels()
            found = list
            note = list.isEmpty
                ? t("model.listsNothing")
                : String(format: t("model.foundCount"), list.count)
        } catch {
            found = []
            note = String(format: t("model.detectFailed"), error.localizedDescription)
        }
    }
}

struct MailTab: View {
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var queue: Queue
    @State private var asksConfirmation = false

    var body: some View {
        Form {
            Section {
                TextField(t("mail.account"), text: $preferences.account)
                TextField(t("mail.mailbox"), text: $preferences.mailbox)
                Picker(t("mail.lookback"), selection: Binding(
                    get: { preferences.period },
                    set: { preferences.period = $0 })) {
                    ForEach(LookBack.allCases) { p in
                        Text(p.name).tag(p)
                    }
                }
                Text(t("mail.lookbackNote"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section {
                Button(t("mail.recheck")) { asksConfirmation = true }
                    .disabled(queue.seen.isEmpty)
                Text(String(format: t("mail.recheckNote"), queue.seen.count))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(t("mail.recheckTitle"), isPresented: $asksConfirmation) {
            Button(t("mail.recheckConfirm"), role: .destructive) { queue.forgetSeen() }
            Button(t("mail.recheckCancel"), role: .cancel) {}
        } message: {
            Text(t("mail.recheckMessage"))
        }
    }
}

struct CreatingTab: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var calendars: [CalendarStore.Choice] = []
    @State private var lists: [CalendarStore.Choice] = []

    var body: some View {
        Form {
            Section {
                TextField(t("create.calendarName"), text: $preferences.calendarName)

                Toggle(t("create.useExisting"), isOn: Binding(
                    get: { !preferences.useOwnCalendar },
                    set: { preferences.useOwnCalendar = !$0 }))

                if !preferences.useOwnCalendar {
                    // Deliberately the loudest thing on the tab. The option is real and the
                    // user asked for it; the reason not to take it should not be buried.
                    Text(t("create.existingWarning"))
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    target(t("create.eventCalendar"), $preferences.eventCalendarId, calendars)
                    target(t("create.reminderList"), $preferences.reminderListId, lists)

                }
                Toggle(t("create.onlyHigh"), isOn: $preferences.onlyHighConfidence)
                Toggle(t("create.auto"), isOn: $preferences.fileAutomatically)
                Text(t("create.autoNote"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Picker(t("create.warnMe"), selection: Binding(
                    get: { preferences.leadTime },
                    set: { preferences.leadTime = $0 })) {
                    ForEach(LeadTime.allCases) { v in
                        Text(v.name).tag(v)
                    }
                }
                Text(t("create.warnNote"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if preferences.useOwnCalendar {
                    Text(t("create.scopeNote"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            let store = CalendarStore(target: .init(ownName: preferences.calendarName))
            calendars = await store.writableCalendars()
            lists = await store.writableLists()
        }
    }

    /// One picker. Read-only calendars are not offered at all, and a stored choice that has
    /// since been deleted keeps its place in the list: dropping it would silently move the
    /// target somewhere else the next time this window opens.
    @ViewBuilder
    private func target(_ label: String, _ choice: Binding<String>,
                        _ options: [CalendarStore.Choice]) -> some View {
        // The app's own one is named in the field above, so name it here too -- "its own"
        // tells you nothing when the answer is sitting three rows higher. Once that calendar
        // exists it is also a normal writable calendar, so it is filtered out of the rest:
        // otherwise the same thing appears twice under two different names.
        let own = preferences.calendarName.trimmingCharacters(in: .whitespaces)
        Picker(label, selection: choice) {
            Text(own.isEmpty ? t("create.ownOne") : own).tag("")
            ForEach(options.filter { $0.title != own }) { c in
                Text(c.account.isEmpty ? c.title : "\(c.title) — \(c.account)").tag(c.id)
            }
            if !choice.wrappedValue.isEmpty,
               !options.contains(where: { $0.id == choice.wrappedValue }) {
                Text(t("create.gone")).tag(choice.wrappedValue)
            }
        }
    }
}
