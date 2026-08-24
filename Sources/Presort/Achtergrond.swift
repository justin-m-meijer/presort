import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// Checks every half minute whether it is time, rather than one timer that fires exactly
/// on the interval. Such a timer skips a turn when the Mac has slept -- and a laptop
/// sleeps more often than it is awake.
@MainActor
final class Wekker: ObservableObject {
    @Published private(set) var volgende: Date?

    private var tik: Timer?
    private var minuten = 0
    private var taak: (() async -> Void)?

    /// Sets the ticker. `minuten` at 0 turns it off.
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

    /// After a manual run the waiting starts over: otherwise the app is back in your
    /// mailbox two minutes later.
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

/// Notifications are the reason the app is allowed to run in the background: without one
/// you would still have to go and look whether anything was found.
enum Meldingen {
    /// Without a bundle id there is no notification centre -- which happens when the
    /// binary is launched on its own instead of from Presort.app.
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

/// Holds on to how the window can be reopened. Needed because a click on a notification
/// arrives outside any window, and SwiftUI only hands out `openWindow` inside a view.
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

/// Makes a notification appear even while the app is in front, and makes a click on it
/// open the window.
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

/// Checking by itself is not much use if the app only runs after you have started it.
/// If enabling that fails, this says why.
@MainActor
enum Inloggen {
    static var isAan: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, otherwise a sentence for the user.
    static func zet(_ aan: Bool) -> String? {
        do {
            if aan {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return String(format: t("login.failed"), error.localizedDescription)
        }
    }
}

/// Is Mail running? An automatic run must not start Mail itself: that would suddenly
/// open an application at night that you had deliberately closed.
enum Mail {
    static var draait: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
    }
}
