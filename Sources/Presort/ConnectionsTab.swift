import SwiftUI

/// Services outside this Mac that Presort can hand things to.
///
/// A tab of its own rather than a few fields tacked onto Creating: what lives here is
/// different in kind from the rest of the settings. Everything else in this app stays on
/// your machine; anything on this tab sends something to a server, which is a decision
/// worth its own place. Each service is a self-contained section that says what it does,
/// what it needs, and whether it works.
struct ConnectionsTab: View {
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle(t("paperless.enable"), isOn: $preferences.paperlessOn)
                if preferences.paperlessOn {
                    TextField(t("paperless.address"), text: $preferences.paperlessAddress,
                              prompt: Text("http://192.168.1.10:8000"))
                    SecureField(t("paperless.token"), text: $preferences.paperlessToken)
                    TextField(t("paperless.tags"), text: $preferences.paperlessTags,
                              prompt: Text("presort"))
                    Toggle(t("paperless.createCorrespondent"),
                           isOn: $preferences.paperlessCreatesCorrespondents)
                    Check(ready: preferences.paperlessReady) {
                        try await Paperless(config: preferences.paperlessConfig).check()
                    }
                }
                Text(t("paperless.note"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(t("paperless.name"))
            }

            Section {
                Toggle(t("parcel.enable"), isOn: $preferences.parcelOn)
                if preferences.parcelOn {
                    SecureField(t("parcel.key"), text: $preferences.parcelKey)
                    TextField(t("parcel.postcode"), text: $preferences.parcelPostcode,
                              prompt: Text("1234 AB"))
                    Toggle(t("parcel.push"), isOn: $preferences.parcelPush)
                    Stepper(value: $preferences.parcelPerDay, in: 0...ParcelApp.dailyLimit) {
                        Text(preferences.parcelPerDay == 0
                             ? t("parcel.perDay.none")
                             : String(format: t("parcel.perDay"), preferences.parcelPerDay))
                    }
                    Check(ready: preferences.parcelReady) {
                        try await ParcelApp(config: preferences.parcelConfig).check()
                    }
                }
                Text(t("parcel.note"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(t("parcel.name"))
            }
        }
        .formStyle(.grouped)
        .task {
            await preferences.loadPaperlessToken()
            await preferences.loadParcelKey()
        }
    }
}

/// A button that actually talks to the server, and repeats what it said.
///
/// Worth its own control because every part of this can fail in a way that looks the same
/// from the outside: a wrong address, a token that was revoked, a path that answers 403
/// because it does not exist. Guessing between those costs an evening; the server will say
/// which it is if anybody asks it.
private struct Check: View {
    let ready: Bool
    let ask: () async throws -> String
    @State private var busy = false
    @State private var note = ""
    @State private var ok = false

    var body: some View {
        HStack(spacing: 8) {
            Button(t("connection.check")) { Task { await run() } }
                .disabled(busy || !ready)
            if busy { ProgressView().controlSize(.small) }
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(ok ? Color.secondary : Color.orange)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private func run() async {
        busy = true
        defer { busy = false }
        do {
            note = try await ask()
            ok = true
        } catch {
            note = error.localizedDescription
            ok = false
        }
    }
}
