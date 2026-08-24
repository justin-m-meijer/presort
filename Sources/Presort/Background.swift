import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// Checks every half minute whether it is time, rather than one timer that fires exactly
/// on the interval. Such a timer skips a turn when the Mac has slept -- and a laptop
/// sleeps more often than it is awake.
@MainActor
final class Alarm: ObservableObject {
    @Published private(set) var next: Date?

    private var tap: Timer?
    private var minutes = 0
    private var task: (() async -> Void)?

    /// Sets the ticker. `minuten` at 0 turns it off.
    func set(every minutes: Int, fire: @escaping () async -> Void) {
        self.minutes = minutes
        self.task = fire
        tap?.invalidate()
        tap = nil

        guard minutes > 0 else {
            next = nil
            return
        }
        next = Date().addingTimeInterval(Double(minutes) * 60)

        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.verify() }
        }
        RunLoop.main.add(t, forMode: .common)
        tap = t
    }

    /// After a manual run the waiting starts over: otherwise the app is back in your
    /// mailbox two minutes later.
    func reschedule() {
        guard minutes > 0 else { return }
        next = Date().addingTimeInterval(Double(minutes) * 60)
    }

    private func verify() async {
        guard let v = next, Date() >= v else { return }
        next = Date().addingTimeInterval(Double(minutes) * 60)
        await task?()
    }
}

/// Notifications are the reason the app is allowed to run in the background: without one
/// you would still have to go and look whether anything was found.
enum Notifier {
    /// Without a bundle id there is no notification centre -- which happens when the
    /// binary is launched on its own instead of from Presort.app.
    private static var possible: Bool { Bundle.main.bundleIdentifier != nil }

    static func askPermission() async {
        guard possible else { return }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    static func post(heading: String, text: String) {
        guard possible, !heading.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = heading
        content.body = text
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Holds on to how the window can be reopened. Needed because a click on a notification
/// arrives outside any window, and SwiftUI only hands out `openWindow` inside a view.
@MainActor
enum Windows {
    nonisolated static let main = "hoofd"

    private static var opener: (() -> Void)?

    static func remember(_ fire: @escaping () -> Void) { opener = fire }

    static func toFront() {
        NSApp.activate(ignoringOtherApps: true)
        opener?()
    }
}

/// Makes a notification appear even while the app is in front, and makes a click on it
/// open the window.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func connect() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ centre: UNUserNotificationCenter,
        willPresent statusLine: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ centre: UNUserNotificationCenter,
        didReceive answer: UNNotificationResponse
    ) async {
        await MainActor.run { Windows.toFront() }
    }
}

/// Checking by itself is not much use if the app only runs after you have started it.
/// If enabling that fails, this says why.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, otherwise a sentence for the user.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
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
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
    }
}
