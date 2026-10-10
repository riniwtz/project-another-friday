import Foundation
import Combine
import UserNotifications
import AppKit

/// System-native notifications. macOS owns their presentation and Focus rules; Hark never draws
/// a fake iOS notification or attempts to bypass notification permissions.
@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var alertsAllowed = false
    @Published private(set) var alertStyle: UNAlertStyle = .none
    @Published private(set) var timeSensitiveAllowed = false
    @Published private(set) var temporarilyMutedUntil: Date?
    @Published var lastError: String?

    private let center = UNUserNotificationCenter.current()
    private let muteAction = "HARK_MUTE_ONE_HOUR"

    override init() {
        super.init()
        center.delegate = self
        let mute = UNNotificationAction(identifier: muteAction, title: "Mute for 1 Hour", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "HARK_SOUND_EVENT", actions: [mute], intentIdentifiers: [], options: [])
        ])
        refreshAuthorization()
    }

    func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in
                self?.authorization = settings.authorizationStatus
                self?.alertsAllowed = settings.alertSetting == .enabled
                self?.alertStyle = settings.alertStyle
                self?.timeSensitiveAllowed = settings.timeSensitiveSetting == .enabled
            }
        }
    }

    func requestAuthorization(completion: (@MainActor (Bool) -> Void)? = nil) {
        center.requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                self?.lastError = error?.localizedDescription
                self?.refreshAuthorization()
                completion?(granted && error == nil)
            }
        }
    }

    var isAuthorized: Bool { authorization == .authorized || authorization == .provisional }

    var isMuted: Bool {
        guard let date = temporarilyMutedUntil else { return false }
        return Date() < date
    }

    func clearMute() { temporarilyMutedUntil = nil }

    func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    func notify(label: String, summary: String, urgent: Bool, playSound: Bool) {
        guard !isMuted else {
            lastError = "Hark alerts are temporarily muted."
            return
        }
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.authorization = settings.authorizationStatus
                self.alertsAllowed = settings.alertSetting == .enabled
                self.alertStyle = settings.alertStyle
                self.timeSensitiveAllowed = settings.timeSensitiveSetting == .enabled
                if settings.authorizationStatus == .notDetermined {
                    self.requestAuthorization { [weak self] granted in
                        guard granted else { return }
                        self?.notify(label: label, summary: summary, urgent: urgent, playSound: playSound)
                    }
                    return
                }
                guard self.isAuthorized else {
                    self.lastError = "Notifications are not authorized for Hark."
                    return
                }
                guard settings.alertSetting == .enabled else {
                    self.lastError = "Notification banners are disabled for Hark in System Settings."
                    return
                }
                self.enqueue(label: label, summary: summary, urgent: urgent, playSound: playSound)
            }
        }
    }

    private func enqueue(label: String, summary: String, urgent: Bool, playSound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = urgent ? "Important: \(label) detected" : "\(label) detected"
        content.subtitle = "Hark detected a sound"
        content.body = summary
        content.categoryIdentifier = "HARK_SOUND_EVENT"
        content.threadIdentifier = "hark.\(label.lowercased().replacingOccurrences(of: " ", with: "-"))"
        // Selected sound alerts are useful only when delivered promptly. Time Sensitive
        // delivery can appear immediately through Focus or a scheduled summary when the
        // user has allowed it; it is not a Critical Alert and never bypasses their choice.
        content.interruptionLevel = timeSensitiveAllowed ? .timeSensitive : .active
        if playSound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { [weak self] error in
            Task { @MainActor [weak self] in self?.lastError = error?.localizedDescription }
        }
    }

    func sendTestNotification(playSound: Bool) {
        notify(label: "Doorbell", summary: "Someone may be at the door. (Synthetic test)", urgent: false, playSound: playSound)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // macOS decides final banner style; banners are non-modal and don't steal keyboard focus.
        var presentation: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil { presentation.insert(.sound) }
        completionHandler(presentation)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "HARK_MUTE_ONE_HOUR" {
            Task { @MainActor [weak self] in self?.temporarilyMutedUntil = Date().addingTimeInterval(3600) }
        }
        completionHandler()
    }

    static func systemImage(for label: String) -> String {
        switch label {
        case "Doorbell": return "bell.and.waves.left.and.right"
        case "Knocking": return "door.left.hand.closed"
        case "Alarm": return "alarm.waves.left.and.right"
        case "Dog barking": return "dog"
        case "Crying": return "drop"
        case "Glass breaking": return "exclamationmark.triangle"
        default: return "speaker.wave.2"
        }
    }
}
