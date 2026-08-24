import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// Kijkt elke halve minuut of het tijd is, in plaats van één timer die precies
/// op het interval afgaat. Zo'n timer slaat een beurt over als de Mac heeft
/// geslapen -- en een laptop slaapt vaker dan hij aan staat.
@MainActor
final class Wekker: ObservableObject {
    @Published private(set) var volgende: Date?

    private var tik: Timer?
    private var minuten = 0
    private var taak: (() async -> Void)?

    /// Zet de wekker. `minuten` op 0 zet hem uit.
    func zet(elke minuten: Int, doe: @escaping () async -> Void) {
        self.minuten = minuten
        self.taak = doe
        tik?.invalidate()
        tik = nil

        guard minuten > 0 else {
            volgende = nil
            return
        }
        volgende = Date().addingTimeInterval(Double(minuten) * 60)

        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.controleer() }
        }
        RunLoop.main.add(t, forMode: .common)
        tik = t
    }

    /// Na een handmatige beurt begint het wachten opnieuw: anders staat de app
    /// twee minuten later alweer in je postvak.
    func schuifOp() {
        guard minuten > 0 else { return }
        volgende = Date().addingTimeInterval(Double(minuten) * 60)
    }

    private func controleer() async {
        guard let v = volgende, Date() >= v else { return }
        volgende = Date().addingTimeInterval(Double(minuten) * 60)
        await taak?()
    }
}

/// Meldingen zijn de reden dat de app op de achtergrond mag draaien: zonder
/// bericht zou je alsnog zelf moeten gaan kijken of er iets gevonden is.
enum Meldingen {
    /// Zonder bundel-id is er geen meldingscentrum -- dat gebeurt als het
    /// programma los wordt gestart in plaats van uit Voorsorteren.app.
    private static var kan: Bool { Bundle.main.bundleIdentifier != nil }

    static func vraagToestemming() async {
        guard kan else { return }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    static func meld(kop: String, tekst: String) {
        guard kan, !kop.isEmpty else { return }
        let inhoud = UNMutableNotificationContent()
        inhoud.title = kop
        inhoud.body = tekst
        inhoud.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: inhoud, trigger: nil))
    }
}

/// Houdt vast hoe je het venster weer open krijgt. Nodig omdat een klik op een
/// melding buiten elk venster om binnenkomt, en SwiftUI zijn `openWindow`
/// alleen binnen een view uitdeelt.
@MainActor
enum Vensters {
    nonisolated static let hoofd = "hoofd"

    private static var opener: (() -> Void)?

    static func onthoud(_ doe: @escaping () -> Void) { opener = doe }

    static func naarVoren() {
        NSApp.activate(ignoringOtherApps: true)
        opener?()
    }
}

/// Zorgt dat een melding ook verschijnt terwijl de app voor staat, en dat een
/// klik erop het venster opent.
final class MeldingBezorger: NSObject, UNUserNotificationCenterDelegate {
    static let gedeeld = MeldingBezorger()

    func koppel() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ centrum: UNUserNotificationCenter,
        willPresent melding: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ centrum: UNUserNotificationCenter,
        didReceive antwoord: UNNotificationResponse
    ) async {
        await MainActor.run { Vensters.naarVoren() }
    }
}

/// Vanzelf nakijken heeft weinig zin als de app pas draait nadat je hem zelf
/// hebt gestart. Lukt het aanzetten niet, dan zegt dit waarom.
@MainActor
enum Inloggen {
    static var isAan: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Geeft nil terug als het gelukt is, anders een zin voor de gebruiker.
    static func zet(_ aan: Bool) -> String? {
        do {
            if aan {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Starten bij inloggen lukte niet. Dat vraagt meestal dat de app in "
                 + "de map Programma's staat. (\(error.localizedDescription))"
        }
    }
}

/// Draait Mail? Een automatische beurt mag Mail niet zelf opstarten: dan opent
/// er 's nachts ineens een programma dat je dicht had gezet.
enum Mail {
    static var draait: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
    }
}
